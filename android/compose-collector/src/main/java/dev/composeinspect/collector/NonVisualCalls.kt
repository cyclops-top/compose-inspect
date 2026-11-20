package dev.composeinspect.collector

/** Composition bookkeeping is omitted, while descendants keep their order and identity. */
internal object NonVisualCalls {
    private val effects = setOf("SideEffect", "DisposableEffect", "LaunchedEffect", "produceState", "derivedStateOf")

    fun shouldFlatten(name: String?, hasLayoutNode: Boolean): Boolean {
        if (hasLayoutNode || name == null) return false
        return name == "remember" ||
            (name.startsWith("<get-") && name.endsWith(">") && name.length > 6) ||
            (name.startsWith("remember") && name.getOrNull(8)?.isUpperCase() == true) || name in effects
    }

    fun <T> retain(name: String?, hasLayoutNode: Boolean, children: List<T>, create: () -> T): List<T> =
        if (shouldFlatten(name, hasLayoutNode)) children else listOf(create())
}
