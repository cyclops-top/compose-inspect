package dev.composeinspect.collector

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsConfiguration
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.semantics.getAllSemanticsNodes
import org.json.JSONObject
import java.lang.reflect.Method

/** Reads only this layout's semantics. Never invokes a click callback or merges child actions. */
class LayoutInteractions(private val host: RootForTest? = null) {
    private val mergedById by lazy { host?.semanticsOwner?.getAllSemanticsNodes(mergingEnabled = true)?.associateBy { it.id } }
    private val idGetters = HashMap<Class<*>, Method>()
    private val getters = HashMap<Class<*>, Method>()

    fun read(node: Any): JSONObject? {
        if (node.javaClass.name != "androidx.compose.ui.node.LayoutNode") return null
        val getter = getters.getOrPut(node.javaClass) {
            node.javaClass.methods.firstOrNull {
                it.parameterCount == 0 && (it.name == "getSemanticsConfiguration" ||
                    it.name.startsWith("getSemanticsConfiguration$"))
            }?.also { it.isAccessible = true }
                ?: throw NoSuchMethodException("LayoutNode.getSemanticsConfiguration")
        }
        val semantics = getter.invoke(node) as? SemanticsConfiguration
        val result = encode(semantics)
        if (semantics != null && host != null) {
            try {
                val idGetter = idGetters.getOrPut(node.javaClass) { node.javaClass.getMethod("getSemanticsId") }
                val merged = mergedById?.get(idGetter.invoke(node) as Int)
                if (merged != null) result.put("merged", encode(merged.config))
            } catch (e: Exception) {
                result.put("mergedError", e.javaClass.simpleName)
            }
        }
        return result
    }

    internal fun encode(semantics: SemanticsConfiguration?): JSONObject = JSONObject()
        .put("hasClickAction", semantics?.getOrNull(SemanticsActions.OnClick)?.action != null)
        .put("hasLongClickAction", semantics?.getOrNull(SemanticsActions.OnLongClick)?.action != null)
        .put("disabled", semantics?.contains(SemanticsProperties.Disabled) == true)
        .put("selected", semantics?.getOrNull(SemanticsProperties.Selected))
        .put("focused", semantics?.getOrNull(SemanticsProperties.Focused))
        .put("toggleableState", semantics?.getOrNull(SemanticsProperties.ToggleableState)?.name)
}
