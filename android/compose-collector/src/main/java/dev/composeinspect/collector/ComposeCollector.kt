@file:OptIn(androidx.compose.ui.tooling.data.UiToolingDataApi::class)

package dev.composeinspect.collector

import android.app.Activity
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import androidx.compose.runtime.tooling.CompositionData
import androidx.compose.runtime.tooling.CompositionGroup
import androidx.compose.runtime.tooling.findCompositionInstance
import androidx.compose.ui.platform.isDebugInspectorInfoEnabled
import androidx.compose.ui.tooling.data.mapTree
import androidx.compose.ui.tooling.data.ContextCache
import dev.composeinspect.protocol.Protocol
import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections
import java.util.IdentityHashMap

/** Reads Compose tooling tables. Does not install an agent or modify business compositions. */
object ComposeCollector {
    private data class Boundary(val layout: Any, val bounds: androidx.compose.ui.unit.IntRect)
    private data class Branch(val nodes: List<NodeDto>, val boundaries: List<Boundary>)

    private val textFields = setOf("text", "style", "color", "fontSize", "fontWeight", "fontFamily",
        "fontStyle", "letterSpacing", "lineHeight", "textAlign", "textDecoration", "overflow", "maxLines", "minLines", "softWrap")
    private val surfaceFields = setOf("shape", "color", "containerColor", "backgroundColor", "contentColor", "enabled")
    private val imageFields = setOf("contentDescription", "tint", "alpha", "contentScale", "alignment")
    private val listFields = setOf("state", "reverseLayout", "userScrollEnabled")
    private fun fieldsFor(name: String?): Set<String> = when {
        name == "Text" || name == "BasicText" -> textFields
        name == "Surface" || name?.endsWith("Button") == true || name?.endsWith("Card") == true -> surfaceFields
        name == "Image" || name == "Icon" -> imageFields
        name == "LazyColumn" || name == "LazyRow" || name == "LazyVerticalGrid" || name == "LazyHorizontalGrid" -> listFields
        else -> emptySet()
    }

    fun enable() {
        // Must run before the first ComposeView composition, including Activity.onCreate.
        isDebugInspectorInfoEnabled = true
    }

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean = false,
                captureWindow: ((View, JSONObject) -> Unit)? = null,
                returnTypes: ComposableReturns = ComposableReturns.empty): JSONObject =
        capture(activities, skipOverlayWindows, captureWindow, returnTypes, onlySourceNodes = false)

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean,
                captureWindow: ((View, JSONObject) -> Unit)?, returnTypes: ComposableReturns,
                onlySourceNodes: Boolean, sourceKeys: Set<String>? = null, componentDetails: Boolean = false): JSONObject {
        check(Looper.myLooper() == Looper.getMainLooper())
        val diagnostics = mutableListOf<String>()
        val warnings = mutableListOf<String>()
        val roots = if (android.os.Build.VERSION.SDK_INT >= 29) {
            WindowInspector.getGlobalWindowViews()
        } else {
            warnings += "API < 29: only Activity decor roots; separate dialog/popup windows may be absent"
            activities.map { it.window.decorView }
        }
        val seen = Collections.newSetFromMap(IdentityHashMap<CompositionData, Boolean>())
        // Lazy item tables share source metadata, but never cache captured application values.
        val contextCache = ContextCache()
        val encoder = if (componentDetails) ValueEncoder() else null
        var styleNanos = 0L
        var parameterNanos = 0L
        var parameterCount = 0
        var treeNanos = 0L
        var groups = 0
        var named = 0
        var located = 0
        var skippedWithoutSource = 0
        var skippedOutsideProject = 0
        var filteredCalls = 0
        var filteredValueCalls = 0
        val topRoot = checkNotNull(WindowSelection.select(roots, skipOverlayWindows)) { "未找到可采集的可见窗口" }
        if (android.os.Build.VERSION.SDK_INT < 29 && !topRoot.hasWindowFocus()) {
            diagnostics += "API < 29: cannot identify the foreground window from Activity decor roots"
        }
        val selectedRoots = if (captureWindow == null) listOf(topRoot) else listOf(topRoot) + roots.asReversed().filter {
            it !== topRoot && it.display?.displayId == topRoot.display?.displayId &&
                WindowSelection.select(listOf(it), skipOverlayWindows) != null
        }
        val windows = selectedRoots.mapIndexed { windowIndex, root ->
            val window = JSONObject()
            var startCopy = captureWindow
            val tables = mutableListOf<JSONObject>()
            val catalogs = JSONArray()
            fun visit(view: View) {
                val data = view.getTag(androidx.compose.ui.R.id.inspection_slot_table_set) as? Set<*>
                val hostTables = data.orEmpty().filterIsInstance<CompositionData>().filter(seen::add)
                if (hostTables.isNotEmpty()) {
                    startCopy?.invoke(root, window)
                    startCopy = null
                    val firstTable = tables.size
                    val included = if (componentDetails && onlySourceNodes) Collections.newSetFromMap(IdentityHashMap<Any, Boolean>()) else null
                    val semantics = if (componentDetails) LayoutInteractions(view as? androidx.compose.ui.node.RootForTest) else null
                    val interactions = IdentityHashMap<Any, Pair<JSONObject?, String?>>()
                    val treeStarted = System.nanoTime()
                    // Compose may return an equal, freshly wrapped parent composition.
                    val anchorsByTable = mutableMapOf<CompositionData, MutableMap<CompositionGroup, MutableList<CompositionData>>>()
                    for (child in hostTables) {
                        val instance = child.findCompositionInstance() ?: continue
                        val parent = instance.parent?.data ?: continue
                        val anchor = instance.findContextGroup() ?: continue
                        anchorsByTable.getOrPut(parent) { mutableMapOf() }.getOrPut(anchor) { mutableListOf() }.add(child)
                    }
                    val trees = IdentityHashMap<CompositionData, List<NodeDto>>()
                    val attached = Collections.newSetFromMap(IdentityHashMap<CompositionData, Boolean>())
                    fun collectTable(table: CompositionData): List<NodeDto> = trees.getOrPut(table) {
                        val anchors = anchorsByTable[table]
                        try {
                            table.mapTree<Branch>(factory = collect@{ group, context, children ->
                                check(++groups <= 30000) { "Group limit exceeded (30000); capture rejected" }
                                val descendants = when (children.size) {
                                    0 -> emptyList()
                                    1 -> children[0].nodes
                                    else -> children.flatMap { it.nodes }
                                }
                                val boundaries = when {
                                    included == null -> emptyList()
                                    group.node != null -> listOf(Boundary(group.node!!, context.bounds))
                                    children.isEmpty() -> emptyList()
                                    children.size == 1 -> children[0].boundaries
                                    else -> children.asSequence().flatMap { it.boundaries }.take(2).toList()
                                }
                                // Attach subcompositions before source filtering lifts this context group.
                                val nested = anchors?.remove(group)
                                val allChildren = if (nested == null) descendants else {
                                    attached.addAll(nested)
                                    descendants + nested.flatMap(::collectTable)
                                }
                                if (group.node == null && returnTypes.returnsValue(context.name, group.sourceInfo)) {
                                    filteredValueCalls++
                                    return@collect Branch(allChildren, boundaries)
                                }
                                if (NonVisualCalls.shouldFlatten(context.name, group.node != null) ||
                                    (group.node == null && returnTypes.forwardsSlot(context.name, group.sourceInfo))) {
                                    filteredCalls++
                                    return@collect Branch(allChildren, boundaries)
                                }
                                val name = context.name
                                val location = context.location
                                if (onlySourceNodes && (name.isNullOrEmpty() || location?.sourceFile.isNullOrBlank())) {
                                    skippedWithoutSource++
                                    return@collect Branch(allChildren, boundaries)
                                }
                                if (onlySourceNodes && sourceKeys != null && location != null) {
                                    val file = java.text.Normalizer.normalize(location.sourceFile!!.substringAfterLast('/'), java.text.Normalizer.Form.NFC)
                                    if ("${location.packageHash}:$file" !in sourceKeys) {
                                        skippedOutsideProject++
                                        return@collect Branch(allChildren, boundaries)
                                    }
                                }
                                val bounds = context.bounds
                                val box = listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
                                if (name != null) named++
                                if (location != null) located++
                                val fields = if (componentDetails) fieldsFor(name) else emptySet()
                                val parameters = if (encoder != null && fields.isNotEmpty()) {
                                    val started = System.nanoTime()
                                    context.parameters.filter { it.name in fields }.map { param ->
                                        val value = LazyViewport.capture(name, param.name, param.value) ?: encoder.encodeCaptured(param.value)
                                        ParameterDto(param.name, value, param.inlineClass, param.fromDefault, param.static, param.compared, param.stable)
                                    }.also { parameterNanos += System.nanoTime() - started; parameterCount += it.size }
                                } else emptyList()
                                val layout = when {
                                    !componentDetails -> null
                                    included == null -> group.node
                                    else -> boundaries.singleOrNull()?.takeIf { it.bounds == bounds }?.layout
                                }
                                val interaction = if (layout != null && semantics != null) {
                                    included?.add(layout)
                                    interactions.getOrPut(layout) {
                                        try { semantics.read(layout) to null }
                                        catch (e: Exception) { null to e.javaClass.simpleName }
                                    }
                                } else null
                                Branch(listOf(NodeDto(name, if (group.node == null) "call" else "layout",
                                    context.isInline, group.sourceInfo, box,
                                    location?.let { SourceDto(it.sourceFile, it.lineNumber, it.offset, it.length, it.packageHash) },
                                    allChildren, layout?.let(System::identityHashCode), interaction?.first, interaction?.second, parameters)), boundaries)
                            }, cache = contextCache)?.nodes.orEmpty()
                        } catch (e: Exception) {
                            diagnostics += "Table capture failed: ${e.javaClass.simpleName}: ${e.message}"
                            emptyList()
                        }
                    }
                    hostTables.forEach(::collectTable)
                    for (table in hostTables) {
                        if (table in attached) continue
                        val tree = JSONObject().put("name", JSONObject.NULL).put("children", Protocol.array(trees.getValue(table)))
                        tables += JSONObject().put("hostView", view.javaClass.name).put("tree", tree)
                    }
                    treeNanos += System.nanoTime() - treeStarted
                    if (componentDetails) {
                        val started = System.nanoTime()
                        LayoutStyles.capture(view, included)?.let { catalog ->
                            for (i in firstTable until tables.size) tables[i].put("styleCatalogIndex", catalogs.length())
                            catalogs.put(catalog)
                        }
                        styleNanos += System.nanoTime() - started
                    }
                }
                if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(root)
            val offset = IntArray(2).also(root::getLocationOnScreen)
            if (onlySourceNodes) window.put("windowSize", JSONArray(listOf(root.width, root.height)))
            window.put("index", windowIndex).put("rootClass", root.javaClass.name)
                .put("screenOffset", JSONArray(offset.toList())).put("tables", Protocol.array(tables))
                .put("styleCatalogs", catalogs)
        }
        val result = JSONObject().put("windows", Protocol.array(windows))
            .put("timings", JSONObject().put("stylesMs", styleNanos / 1e6)
                .put("treeMs", treeNanos / 1e6).put("parameterExtractionMs", parameterNanos / 1e6))
            .put("stats", JSONObject().put("tables", seen.size).put("groups", groups)
                .put("namedGroups", named).put("groupsWithSource", located).put("parameters", parameterCount)
                .put("filteredNonVisualCalls", filteredCalls).put("filteredValueCalls", filteredValueCalls))
            .put("warnings", Protocol.array(warnings))
            .put("diagnostics", Protocol.array(diagnostics))
            .put("complete", diagnostics.isEmpty())
        result.put("geometryOnly", !componentDetails)
        if (onlySourceNodes) {
            result.put("onlySourceNodes", true)
            result.getJSONObject("stats").put("skippedWithoutSource", skippedWithoutSource)
            if (sourceKeys != null) {
                result.put("projectSourcesOnly", true)
                result.getJSONObject("stats").put("skippedOutsideProject", skippedOutsideProject)
            }
        }
        return result
    }
}
