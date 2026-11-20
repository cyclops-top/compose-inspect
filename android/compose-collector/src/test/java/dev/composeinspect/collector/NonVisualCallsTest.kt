package dev.composeinspect.collector

import org.junit.Assert.*
import org.junit.Test

class NonVisualCallsTest {
    @Test fun removesBookkeepingWithoutEvaluatingItsParametersOrDroppingChildren() {
        for (name in listOf("remember", "rememberSaveable", "rememberAppState", "LaunchedEffect", "SideEffect", "produceState", "<get-current>", "<get-colors>")) {
            val children = listOf("Text", "Button")
            assertEquals(children, NonVisualCalls.retain(name, false, children) { error("Filtered call must not be encoded") })
        }
    }

    @Test fun preservesBusinessUiUnknownCallsAndMeasuredNodes() {
        for (name in listOf(null, "Screen", "Button", "rememberingWidget", "calculateSize", "getCurrent", "<get->", "<get-current")) {
            assertFalse(NonVisualCalls.shouldFlatten(name, false))
        }
        assertFalse(NonVisualCalls.shouldFlatten("remember", true))
        assertEquals(listOf("parent"), NonVisualCalls.retain("Screen", false, listOf("child")) { "parent" })
    }
}
