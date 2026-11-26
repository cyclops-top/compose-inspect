package dev.composeinspect.collector

/** Composition bookkeeping is omitted, while descendants keep their order and identity. */
internal object NonVisualCalls {
    private val compositionWrappers = setOf(
        "CompositionLocalProvider", "ProvideCommonCompositionLocals",
        "ProvideTextStyle", "ProvideContentColorTextStyle", "SaveableStateProvider",
        "ReusableContent", "ReusableContentHost", "LazyLayoutPinnableItem", "SkippableItem",
    )
    private val effects = setOf("SideEffect", "DisposableEffect", "LaunchedEffect", "produceState", "derivedStateOf")

    fun shouldFlatten(name: String?, hasLayoutNode: Boolean): Boolean {
        if (hasLayoutNode || name == null) return false
        return name in compositionWrappers || name == "remember" ||
            (name.startsWith("<get-") && name.endsWith(">") && name.length > 6) ||
            (name.startsWith("remember") && name.getOrNull(8)?.isUpperCase() == true) || name in effects
    }
}
