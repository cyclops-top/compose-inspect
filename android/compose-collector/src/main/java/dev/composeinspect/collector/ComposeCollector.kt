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

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean = false,
                captureWindow: ((View, JSONObject) -> Unit)? = null,
                returnTypes: ComposableReturns = ComposableReturns.empty): JSONObject =
        capture(activities, skipOverlayWindows, captureWindow, returnTypes, onlySourceNodes = false)

    fun capture(activities: Collection<Activity>, skipOverlayWindows: Boolean,
                captureWindow: ((View, JSONObject) -> Unit)?, returnTypes: ComposableReturns,
                onlySourceNodes: Boolean, sourceKeys: Set<String>? = null): JSONObject {
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
            fun visit(view: View) {
                val data = view.getTag(androidx.compose.ui.R.id.inspection_slot_table_set) as? Set<*>
                data?.filterIsInstance<CompositionData>()?.forEach { table ->
                    if (seen.add(table)) {
                        startCopy?.invoke(root, window)
                        startCopy = null
                        try {
                            val treeStarted = System.nanoTime()
                            val tree = table.mapTree<List<NodeDto>>(factory = collect@{ group, context, children ->
                                check(++groups <= 30000) { "Group limit exceeded (30000); capture rejected" }
                                val descendants = children.flatten()
                                if (group.node == null && returnTypes.returnsValue(context.name, group.sourceInfo)) {
                                    filteredValueCalls++
                                    return@collect descendants
                                }
                                if (NonVisualCalls.shouldFlatten(context.name, group.node != null)) {
                                    filteredCalls++
                                    return@collect descendants
                                }
                                val name = context.name
                                val location = context.location
                                if (onlySourceNodes && (name.isNullOrEmpty() || location?.sourceFile.isNullOrBlank())) {
                                    skippedWithoutSource++
                                    return@collect descendants
                                }
                                if (onlySourceNodes && sourceKeys != null && location != null) {
                                    val file = java.text.Normalizer.normalize(location.sourceFile!!.substringAfterLast('/'), java.text.Normalizer.Form.NFC)
                                    if ("${location.packageHash}:$file" !in sourceKeys) {
                                        skippedOutsideProject++
                                        return@collect descendants
                                    }
                                }
                                val bounds = context.bounds
                                val box = listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)
                                if (name != null) named++
                                if (location != null) located++
                                listOf(NodeDto(name, if (group.node == null) "call" else "layout",
                                    context.isInline, group.sourceInfo, box,
                                    location?.let { SourceDto(it.sourceFile, it.lineNumber, it.offset, it.length, it.packageHash) },
                                    descendants))
                            }, cache = contextCache)
                            treeNanos += System.nanoTime() - treeStarted
                            // A table may now have multiple roots after lifting bookkeeping calls.
                            val root = JSONObject().put("name", JSONObject.NULL).put("children", Protocol.array(tree.orEmpty()))
                            tables += JSONObject().put("hostView", view.javaClass.name).put("tree", root)
                        } catch (e: Exception) {
                            diagnostics += "Table capture failed: ${e.javaClass.simpleName}: ${e.message}"
                        }
                    }
                }
                if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
            }
            visit(root)
            val offset = IntArray(2).also(root::getLocationOnScreen)
            if (onlySourceNodes) window.put("windowSize", JSONArray(listOf(root.width, root.height)))
            window.put("index", windowIndex).put("rootClass", root.javaClass.name)
                .put("screenOffset", JSONArray(offset.toList())).put("tables", Protocol.array(tables))
                .put("styleCatalogs", JSONArray())
        }
        val result = JSONObject().put("windows", Protocol.array(windows))
            .put("timings", JSONObject().put("stylesMs", 0)
                .put("treeMs", treeNanos / 1e6).put("parameterExtractionMs", 0))
            .put("stats", JSONObject().put("tables", seen.size).put("groups", groups)
                .put("namedGroups", named).put("groupsWithSource", located).put("parameters", 0)
                .put("filteredNonVisualCalls", filteredCalls).put("filteredValueCalls", filteredValueCalls))
            .put("warnings", Protocol.array(warnings))
            .put("diagnostics", Protocol.array(diagnostics))
            .put("complete", diagnostics.isEmpty())
        result.put("geometryOnly", true)
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
