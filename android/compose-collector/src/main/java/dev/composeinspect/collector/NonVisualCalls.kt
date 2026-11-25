package dev.composeinspect.collector

/** Composition bookkeeping is omitted, while descendants keep their order and identity. */
internal object NonVisualCalls {
    private val effects = setOf("SideEffect", "DisposableEffect", "LaunchedEffect", "produceState", "derivedStateOf")

    fun shouldFlatten(name: String?, hasLayoutNode: Boolean): Boolean {
        if (hasLayoutNode || name == null) return false
        return name == "CompositionLocalProvider" || name == "remember" ||
            (name.startsWith("<get-") && name.endsWith(">") && name.length > 6) ||
            (name.startsWith("remember") && name.getOrNull(8)?.isUpperCase() == true) || name in effects
    }

    // A direct layout boundary may implement the caller's own draw/input modifiers.
    // Keep it and its owner when no named child can own that boundary.
    fun isForwardingCall(name: String, children: List<NodeDto>): Boolean {
        if (name in retainedUi) return false
        var branch = children
        while (true) {
            val child = branch.singleOrNull {
                val b = it.boundsInWindow
                b.size == 4 && b[2] > b[0] && b[3] > b[1]
            } ?: return false
            if (child.kind == "layout") return false
            if (child.name != null) return true
            branch = child.children
        }
    }

    private val retainedUi = setOf("Text", "BasicText", "Image", "Icon", "Canvas", "Button",
        "Box", "BoxWithConstraints", "Row", "Column", "Layout", "SubcomposeLayout",
        "LazyLayout", "SkippableItem", "LazyLayoutPinnableItem", "AnimatedVisibility")
}
