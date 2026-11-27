package dev.composeinspect.collector

/** Composition bookkeeping is omitted, while descendants keep their order and identity. */
internal object NonVisualCalls {
    private val compositionWrappers = setOf(
        "CompositionLocalProvider", "ProvideCommonCompositionLocals",
        "ProvideTextStyle", "ProvideContentColorTextStyle", "SaveableStateProvider",
        "ReusableContent", "ReusableContentHost", "LazyLayoutPinnableItem", "SkippableItem",
    )
    private val effects = setOf("SideEffect", "DisposableEffect", "LaunchedEffect", "produceState", "derivedStateOf")

    // Match the declaration file and package hash. The call-site file can belong to the caller.
    fun isKnownNonVisualLeaf(name: String?, sourceInfo: String?): Boolean = when (name) {
        "collectInto" -> sourceInfo?.endsWith(":SnapshotFlow.kt#9igjgp") == true
        "BackgroundTextMeasurement" -> sourceInfo?.endsWith(":BasicText.android.kt#423gt5") == true
        else -> false
    }

    fun shouldFlatten(name: String?, hasLayoutNode: Boolean): Boolean {
        if (hasLayoutNode || name == null) return false
        return name in compositionWrappers || name == "remember" ||
            (name.startsWith("<get-") && name.endsWith(">") && name.length > 6) ||
            (name.startsWith("remember") && name.getOrNull(8)?.isUpperCase() == true) || name in effects
    }
}
