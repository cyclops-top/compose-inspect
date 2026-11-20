package dev.composeinspect.collector

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsConfiguration
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import org.json.JSONObject
import java.lang.reflect.Method

/** Reads only this layout's semantics. Never invokes a click callback or merges child actions. */
class LayoutInteractions {
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
        return encode(getter.invoke(node) as? SemanticsConfiguration)
    }

    internal fun encode(semantics: SemanticsConfiguration?): JSONObject = JSONObject()
        .put("hasClickAction", semantics?.getOrNull(SemanticsActions.OnClick)?.action != null)
        .put("hasLongClickAction", semantics?.getOrNull(SemanticsActions.OnLongClick)?.action != null)
        .put("disabled", semantics?.contains(SemanticsProperties.Disabled) == true)
}
