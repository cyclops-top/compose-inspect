package dev.composeinspect.collector

import android.view.View
import android.view.WindowManager.LayoutParams

internal object WindowSelection {
    fun select(roots: List<View>, skipOverlays: Boolean): View? =
        select(roots, skipOverlays,
            visible = { it.isAttachedToWindow && it.isShown && it.windowVisibility == View.VISIBLE },
            overlay = { ((it.layoutParams as? LayoutParams)?.type ?: 0) >= LayoutParams.FIRST_SYSTEM_WINDOW },
            focused = View::hasWindowFocus,
            panelOf = { root, parent ->
                val params = root.layoutParams as? LayoutParams
                params?.token != null && params.token == parent.windowToken && when (params.type) {
                    LayoutParams.TYPE_APPLICATION_PANEL, LayoutParams.TYPE_APPLICATION_SUB_PANEL,
                    LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG,
                    LayoutParams.FIRST_SUB_WINDOW + 5 -> true // TYPE_APPLICATION_ABOVE_SUB_PANEL is hidden.
                    else -> false
                }
            })

    fun <T> select(roots: List<T>, skipOverlays: Boolean, visible: (T) -> Boolean,
                   overlay: (T) -> Boolean, focused: (T) -> Boolean, panelOf: (T, T) -> Boolean): T? {
        val candidates = roots.filter { visible(it) && (!skipOverlays || !overlay(it)) }
        // Non-focusable overlays must not lose to the focused Activity underneath.
        candidates.lastOrNull(overlay)?.let { return it }
        val parent = candidates.lastOrNull(focused) ?: return candidates.lastOrNull()
        return candidates.lastOrNull { panelOf(it, parent) } ?: parent
    }
}
