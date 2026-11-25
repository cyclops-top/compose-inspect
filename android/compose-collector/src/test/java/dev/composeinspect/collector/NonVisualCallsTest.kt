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
        val child = NodeDto("Text", "call", null, null, null, false, null, listOf(0, 0, 10, 20), null, emptyList(), emptyList())
        assertTrue(NonVisualCalls.isForwardingCall("ArticleScope", listOf(child)))
        assertFalse(NonVisualCalls.isForwardingCall("Text", listOf(child)))
        assertFalse(NonVisualCalls.isForwardingCall("ArticleScope", listOf(child, child)))
        assertFalse(NonVisualCalls.isForwardingCall("ArticleScope", listOf(child.copy(name = null, kind = "layout"))))
    }
}
