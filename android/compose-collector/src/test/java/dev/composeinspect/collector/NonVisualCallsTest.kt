package dev.composeinspect.collector

import org.junit.Assert.*
import org.junit.Test

class NonVisualCallsTest {
    @Test fun recognizesBookkeepingBeforeParameterExtraction() {
        for (name in listOf("remember", "rememberSaveable", "rememberAppState", "LaunchedEffect", "SideEffect", "produceState", "<get-current>", "<get-colors>")) {
            assertTrue(NonVisualCalls.shouldFlatten(name, false))
        }
    }

    @Test fun preservesBusinessUiUnknownCallsAndMeasuredNodes() {
        for (name in listOf(null, "Screen", "Button", "rememberingWidget", "calculateSize", "getCurrent", "<get->", "<get-current")) {
            assertFalse(NonVisualCalls.shouldFlatten(name, false))
        }
        assertFalse(NonVisualCalls.shouldFlatten("remember", true))
    }
}
