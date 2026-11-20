package dev.composeinspect.collector

import org.junit.Assert.*
import org.junit.Test

class WindowSelectionTest {
    private data class Root(val overlay: Boolean = false, val focused: Boolean = false, val visible: Boolean = true, val parent: Root? = null)
    private fun select(roots: List<Root>, skip: Boolean = false) =
        WindowSelection.select(roots, skip, Root::visible, Root::overlay, Root::focused) { root, parent -> root.parent === parent }

    @Test fun nonFocusableOverlayWinsOverFocusedActivityRegardlessOfEnumerationOrder() {
        val activity = Root(focused = true)
        val overlay = Root(overlay = true)
        assertSame(overlay, select(listOf(activity, overlay)))
        assertSame(overlay, select(listOf(overlay, activity)))
        assertSame(activity, select(listOf(activity, overlay), skip = true))
    }

    @Test fun hiddenOverlaysAndToggleChangesDoNotLeaveStaleSelection() {
        val activity = Root(focused = true)
        val hidden = Root(overlay = true, visible = false)
        val overlay = Root(overlay = true)
        assertSame(activity, select(listOf(activity, hidden)))
        val roots = listOf(activity, overlay)
        assertSame(overlay, select(roots))
        assertSame(activity, select(roots, skip = true))
        assertSame(overlay, select(roots))
        assertNull(select(listOf(overlay), skip = true))
    }

    @Test fun nonFocusablePanelBelongsToFocusedWindow() {
        val activity = Root(focused = true)
        val popup = Root(parent = activity)
        val unrelated = Root(parent = Root())
        for (skip in listOf(false, true)) {
            assertSame(popup, select(listOf(activity, popup, unrelated), skip))
            assertSame(activity, select(listOf(activity, unrelated), skip))
        }
    }

    @Test fun ordinaryFocusedDialogsRemainSelectedWithoutSystemOverlays() {
        val activity = Root()
        val dialog = Root(focused = true)
        assertSame(dialog, select(listOf(activity, dialog)))
        assertSame(dialog, select(listOf(activity, dialog), skip = true))
    }
}
