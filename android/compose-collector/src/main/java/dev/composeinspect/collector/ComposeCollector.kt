@file:OptIn(androidx.compose.ui.tooling.data.UiToolingDataApi::class)

package dev.composeinspect.collector

import android.app.Activity
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import androidx.compose.runtime.tooling.CompositionData
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
    fun enable() {
        // Must run before the first ComposeView composition, including Activity.onCreate.
        isDebugInspectorInfoEnabled = true
    }

    private data class LayoutBoundary(val node: Any, val bounds: androidx.compose.ui.unit.IntRect)
    private data class Branch(val nodes: List<NodeDto>, val layouts: List<LayoutBoundary>)

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean = false,
                captureWindow: ((View, JSONObject) -> Unit)? = null,
                returnTypes: ComposableReturns = ComposableReturns.empty): JSONObject =
        capture(activities, skipOverlayWindows, captureWindow, returnTypes, onlySourceNodes = false)

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean,
                captureWindow: ((View, JSONObject) -> Unit)?, returnTypes: ComposableReturns,
                onlySourceNodes: Boolean, sourceKeys: Set<String>? = null): JSONObject {
        check(Looper.myLooper() == Looper.getMainLooper())
        val captureStarted = System.nanoTime()
        val diagnostics = mutableListOf<String>()
        val warnings = mutableListOf<String>()
        val roots = if (android.os.Build.VERSION.SDK_INT >= 29) {
            WindowInspector.getGlobalWindowViews()
        } else {
            warnings += "API < 29: only Activity decor roots; separate dialog/popup windows may be absent"
            activities.map { it.window.decorView }
        }
        val seen = Collections.newSetFromMap(IdentityHashMap<CompositionData, Boolean>())
        val valueEncoder = ValueEncoder()
        // Lazy item tables share source metadata, but never cache captured application values.
        val contextCache = ContextCache()
        var styleNanos = 0L
        var treeNanos = 0L
        var parameterNanos = 0L
        var encodingNanos = 0L
        var valueNanos = 0L
        var nodeDtoNanos = 0L
        var metadataNanos = 0L
        var flattenNanos = 0L
        var factoryNanos = 0L
        var propertyNanos = 0L
        var interactionNanos = 0L
        var interactionCalls = 0
        var views = 0
        var groups = 0
        var named = 0
        var located = 0
        var parameters = 0
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
            val styleCatalogs = mutableListOf<JSONObject>()
            fun visit(view: View) {
                views++
                val data = view.getTag(androidx.compose.ui.R.id.inspection_slot_table_set) as? Set<*>
                val includedLayouts = if (onlySourceNodes) Collections.newSetFromMap(IdentityHashMap<Any, Boolean>()) else null
                val cachedInteractions = IdentityHashMap<Any, Pair<JSONObject?, String?>>()
                val firstTable = tables.size
                val interactions = LayoutInteractions(if (data.isNullOrEmpty()) null else view as? androidx.compose.ui.node.RootForTest)
                data?.filterIsInstance<CompositionData>()?.forEach { table ->
                    if (seen.add(table)) {
                        startCopy?.invoke(root, window)
                        startCopy = null
                        try {
                            val treeStarted = System.nanoTime()
                            val tree = table.mapTree<Branch>(factory = collect@{ group, context, children ->
                                val factoryStarted = System.nanoTime()
                                try {
                                check(++groups <= 30000) { "Group limit exceeded (30000); capture rejected" }
                                val flattenStarted = System.nanoTime()
                                val descendants = children.flatMap { it.nodes }
                                // Two roots suffice to distinguish ambiguous ownership. Carry these
                                // through skipped calls without retaining their arguments or DTOs.
                                val layouts = when {
                                    !onlySourceNodes -> emptyList()
                                    group.node != null -> listOf(LayoutBoundary(group.node!!, context.bounds))
                                    else -> children.asSequence().flatMap { it.layouts }.take(2).toList()
                                }
                                val promoted = Branch(descendants, layouts)
                                flattenNanos += System.nanoTime() - flattenStarted
                                if (group.node == null && returnTypes.returnsValue(context.name, group.sourceInfo)) {
                                    filteredValueCalls++
                                    return@collect promoted
                                }
                                if (NonVisualCalls.shouldFlatten(context.name, group.node != null)) {
                                    filteredCalls++
                                    return@collect promoted
                                }
                                val name = context.name
                                val location = context.location
                                if (onlySourceNodes && (name.isNullOrEmpty() || location?.sourceFile.isNullOrBlank())) {
                                    skippedWithoutSource++
                                    return@collect promoted
                                }
                                if (onlySourceNodes && sourceKeys != null && location != null) {
                                    val file = java.text.Normalizer.normalize(location.sourceFile!!.substringAfterLast('/'), java.text.Normalizer.Form.NFC)
                                    if ("${location.packageHash}:$file" !in sourceKeys) {
                                        skippedOutsideProject++
                                        return@collect promoted
                                    }
                                }
                                val parameterStarted = System.nanoTime()
                                val params = context.parameters
                                parameterNanos += System.nanoTime() - parameterStarted
                                val propertyStarted = System.nanoTime()
                                val bounds = context.bounds
                                propertyNanos += System.nanoTime() - propertyStarted
                                val box = listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
                                val slot = params.singleOrNull { it.value is androidx.compose.runtime.internal.ComposableLambda }
                                val forwardsContent = slot != null && group.node == null && sharesContentBounds(box, descendants)
                                if (forwardsContent && name != null && params.all {
                                        it === slot || it.fromDefault || it.value === androidx.compose.ui.Modifier
                                    } && NonVisualCalls.isForwardingCall(name, descendants)) {
                                    filteredCalls++
                                    return@collect promoted
                                }
                                if (name != null) named++
                                if (location != null) located++
                                parameters += params.size
                                val metadataStarted = System.nanoTime()
                                val inline = context.isInline
                                val sourceInfo = group.sourceInfo
                                metadataNanos += System.nanoTime() - metadataStarted
                                val nodeStarted = System.nanoTime()
                                val encodingBefore = encodingNanos
                                val interactionBefore = interactionNanos
                                val layoutNode = if (onlySourceNodes) layouts.singleOrNull()?.takeIf { it.bounds == bounds }?.node else group.node
                                var interaction: JSONObject? = null
                                var interactionError: String? = null
                                if (layoutNode != null) {
                                    val interactionStarted = System.nanoTime()
                                    val cached = cachedInteractions[layoutNode]
                                    if (cached != null) {
                                        interaction = cached.first
                                        interactionError = cached.second
                                    } else {
                                        interactionCalls++
                                        try { interaction = interactions.read(layoutNode) }
                                        catch (e: Exception) { interactionError = e.javaClass.simpleName }
                                        if (includedLayouts != null) {
                                            includedLayouts.add(layoutNode)
                                            cachedInteractions[layoutNode] = interaction to interactionError
                                        }
                                    }
                                    interactionNanos += System.nanoTime() - interactionStarted
                                }
                                val encodingStarted = System.nanoTime()
                                val capturedParameters = params.map {
                                    val valueStarted = System.nanoTime()
                                    val encodedValue = LazyViewport.capture(name, it.name, it.value) ?: valueEncoder.encodeCaptured(it.value)
                                    valueNanos += System.nanoTime() - valueStarted
                                    ParameterDto(it.name, encodedValue, it.inlineClass, it.fromDefault,
                                        it.static, it.compared, it.stable,
                                        forwardsContent = if (it.value is androidx.compose.runtime.internal.ComposableLambda) forwardsContent else null)
                                }
                                encodingNanos += System.nanoTime() - encodingStarted
                                Branch(listOf(NodeDto(name, if (group.node == null) "call" else "layout",
                                    layoutNode?.let(System::identityHashCode), interaction, interactionError,
                                    inline, sourceInfo, box,
                                    location?.let { SourceDto(it.sourceFile, it.lineNumber, it.offset, it.length, it.packageHash) },
                                    capturedParameters, descendants).also {
                                    nodeDtoNanos += System.nanoTime() - nodeStarted -
                                        (encodingNanos - encodingBefore) - (interactionNanos - interactionBefore)
                                }), layouts)
                                } finally { factoryNanos += System.nanoTime() - factoryStarted }
                            }, cache = contextCache)
                            treeNanos += System.nanoTime() - treeStarted
                            // A table may now have multiple roots after lifting bookkeeping calls.
                            val root = JSONObject().put("name", JSONObject.NULL).put("children", Protocol.array(tree?.nodes.orEmpty()))
                            tables += JSONObject().put("hostView", view.javaClass.name).put("tree", root)
                        } catch (e: Exception) {
                            diagnostics += "Table capture failed: ${e.javaClass.simpleName}: ${e.message}"
                        }
                    }
                }
                if (!data.isNullOrEmpty()) {
                    val started = System.nanoTime()
                    LayoutStyles.capture(view, includedLayouts)?.let { catalog ->
                        for (i in firstTable until tables.size) tables[i].put("styleCatalogIndex", styleCatalogs.size)
                        styleCatalogs.add(catalog)
                    }
                    styleNanos += System.nanoTime() - started
                }
                if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(root)
            val offset = IntArray(2).also(root::getLocationOnScreen)
            if (onlySourceNodes) window.put("windowSize", JSONArray(listOf(root.width, root.height)))
            window.put("index", windowIndex).put("rootClass", root.javaClass.name)
                .put("screenOffset", JSONArray(offset.toList())).put("tables", Protocol.array(tables))
                .put("styleCatalogs", Protocol.array(styleCatalogs))
        }
        val result = JSONObject().put("windows", Protocol.array(windows))
            .put("timings", JSONObject().put("stylesMs", styleNanos / 1e6)
                .put("treeMs", treeNanos / 1e6).put("parameterExtractionMs", parameterNanos / 1e6))
            .put("stats", JSONObject().put("tables", seen.size).put("groups", groups)
                .put("namedGroups", named).put("groupsWithSource", located).put("parameters", parameters)
                .put("filteredNonVisualCalls", filteredCalls).put("filteredValueCalls", filteredValueCalls))
            .put("warnings", Protocol.array(warnings))
            .put("diagnostics", Protocol.array(diagnostics))
            .put("complete", diagnostics.isEmpty())
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
