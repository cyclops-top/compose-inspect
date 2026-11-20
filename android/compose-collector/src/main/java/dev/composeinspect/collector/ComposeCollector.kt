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

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean = false): JSONObject {
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
        val interactions = LayoutInteractions()
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
        var filteredCalls = 0
        val topRoot = checkNotNull(WindowSelection.select(roots, skipOverlayWindows)) { "未找到可采集的可见窗口" }
        if (android.os.Build.VERSION.SDK_INT < 29 && !topRoot.hasWindowFocus()) {
            diagnostics += "API < 29: cannot identify the foreground window from Activity decor roots"
        }
        val windows = listOfNotNull(topRoot).mapIndexed { windowIndex, root ->
            val tables = mutableListOf<JSONObject>()
            val styleCatalogs = mutableListOf<JSONObject>()
            fun visit(view: View) {
                views++
                val data = view.getTag(androidx.compose.ui.R.id.inspection_slot_table_set) as? Set<*>
                val styleStarted = System.nanoTime()
                val styleCatalog = if (!data.isNullOrEmpty()) LayoutStyles.capture(view) else null
                styleNanos += System.nanoTime() - styleStarted
                val styleCatalogIndex = styleCatalog?.let {
                    styleCatalogs.add(it)
                    styleCatalogs.lastIndex
                }
                data?.filterIsInstance<CompositionData>()?.forEach { table ->
                    if (seen.add(table)) {
                        try {
                            val treeStarted = System.nanoTime()
                            val tree = table.mapTree<List<NodeDto>>(factory = { group, context, children ->
                                val factoryStarted = System.nanoTime()
                                try {
                                check(++groups <= 30000) { "Group limit exceeded (30000); capture rejected" }
                                val flattenStarted = System.nanoTime()
                                val descendants = children.flatten()
                                flattenNanos += System.nanoTime() - flattenStarted
                                val flatten = NonVisualCalls.shouldFlatten(context.name, group.node != null)
                                if (flatten) filteredCalls++
                                NonVisualCalls.retain(context.name, group.node != null, descendants) {
                                val parameterStarted = System.nanoTime()
                                val params = context.parameters
                                parameterNanos += System.nanoTime() - parameterStarted
                                val propertyStarted = System.nanoTime()
                                val name = context.name
                                val location = context.location
                                val bounds = context.bounds
                                propertyNanos += System.nanoTime() - propertyStarted
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
                                val layoutNode = group.node
                                var interaction: JSONObject? = null
                                var interactionError: String? = null
                                if (layoutNode != null) {
                                    val interactionStarted = System.nanoTime()
                                    interactionCalls++
                                    try { interaction = interactions.read(layoutNode) }
                                    catch (e: Exception) { interactionError = e.javaClass.simpleName }
                                    finally { interactionNanos += System.nanoTime() - interactionStarted }
                                }
                                val encodingStarted = System.nanoTime()
                                val capturedParameters = params.map {
                                    val valueStarted = System.nanoTime()
                                    val encodedValue = valueEncoder.encodeCaptured(it.value)
                                    valueNanos += System.nanoTime() - valueStarted
                                    ParameterDto(it.name, encodedValue, it.inlineClass, it.fromDefault,
                                        it.static, it.compared, it.stable)
                                }
                                encodingNanos += System.nanoTime() - encodingStarted
                                NodeDto(name, if (layoutNode == null) "call" else "layout",
                                    layoutNode?.let(System::identityHashCode), interaction, interactionError,
                                    inline, sourceInfo, listOf(bounds.left, bounds.top, bounds.right, bounds.bottom),
                                    location?.let { SourceDto(it.sourceFile, it.lineNumber, it.offset, it.length, it.packageHash) },
                                    capturedParameters, descendants).also {
                                    nodeDtoNanos += System.nanoTime() - nodeStarted -
                                        (encodingNanos - encodingBefore) - (interactionNanos - interactionBefore)
                                }
                                }
                                } finally { factoryNanos += System.nanoTime() - factoryStarted }
                            }, cache = contextCache)
                            treeNanos += System.nanoTime() - treeStarted
                            // A table may now have multiple roots after lifting bookkeeping calls.
                            val root = JSONObject().put("name", JSONObject.NULL).put("children", Protocol.array(tree ?: emptyList()))
                            tables += JSONObject().put("hostView", view.javaClass.name).put("tree", root)
                                .apply { if (styleCatalogIndex != null) put("styleCatalogIndex", styleCatalogIndex) }
                        } catch (e: Exception) {
                            diagnostics += "Table capture failed: ${e.javaClass.simpleName}: ${e.message}"
                        }
                    }
                }
                if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(root)
            val offset = IntArray(2).also(root::getLocationOnScreen)
            JSONObject().put("index", windowIndex).put("rootClass", root.javaClass.name)
                .put("screenOffset", JSONArray(offset.toList())).put("tables", Protocol.array(tables))
                .put("styleCatalogs", Protocol.array(styleCatalogs))
        }
        val result = JSONObject().put("windows", Protocol.array(windows))
            .put("timings", JSONObject().put("stylesMs", styleNanos / 1e6)
                .put("treeMs", treeNanos / 1e6).put("parameterExtractionMs", parameterNanos / 1e6))
            .put("stats", JSONObject().put("tables", seen.size).put("groups", groups)
                .put("namedGroups", named).put("groupsWithSource", located).put("parameters", parameters)
                .put("filteredNonVisualCalls", filteredCalls))
            .put("warnings", Protocol.array(warnings))
            .put("diagnostics", Protocol.array(diagnostics))
            .put("complete", diagnostics.isEmpty())
        return result
    }
}
