package dev.composeinspect.collector

import androidx.compose.ui.semantics.AccessibilityAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsConfiguration
import androidx.compose.ui.semantics.SemanticsProperties
import org.junit.Assert.*
import org.junit.Test

class LayoutInteractionsTest {
    private val reader = LayoutInteractions()

    @Test fun reportsOwnActionsWithoutInvokingThem() {
        var invoked = false
        val semantics = SemanticsConfiguration().apply {
            this[SemanticsActions.OnClick] = AccessibilityAction("Open") { invoked = true; true }
            this[SemanticsActions.OnLongClick] = AccessibilityAction("Menu") { invoked = true; true }
        }
        val result = reader.encode(semantics)
        assertTrue(result.getBoolean("hasClickAction"))
        assertTrue(result.getBoolean("hasLongClickAction"))
        assertFalse(result.getBoolean("disabled"))
        assertFalse(invoked)
    }

    @Test fun preservesDisabledAndDoesNotTreatLabelOnlyOrLongClickAsClick() {
        val semantics = SemanticsConfiguration().apply {
            this[SemanticsActions.OnClick] = AccessibilityAction("No callback", null)
            this[SemanticsActions.OnLongClick] = AccessibilityAction("Menu") { true }
            this[SemanticsProperties.Disabled] = Unit
        }
        val result = reader.encode(semantics)
        assertFalse(result.getBoolean("hasClickAction"))
        assertTrue(result.getBoolean("hasLongClickAction"))
        assertTrue(result.getBoolean("disabled"))
        assertFalse(reader.encode(null).getBoolean("hasClickAction"))
        assertFalse(reader.encode(SemanticsConfiguration()).getBoolean("hasClickAction"))
    }
}
