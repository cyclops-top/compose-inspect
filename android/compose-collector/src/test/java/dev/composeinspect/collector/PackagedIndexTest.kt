package dev.composeinspect.collector

import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.util.zip.ZipFile

class PackagedIndexTest {
    @Test fun packagedIndexMatchesFinalDex() {
        val apk = System.getenv("COMPOSEINSPECT_INDEX_APK")
        assumeTrue("Requires a plugin-enabled debug APK", !apk.isNullOrEmpty())
        val packaged = ZipFile(apk!!).use { zip ->
            zip.getInputStream(zip.getEntry("assets/" + ComposableReturns.assetName)).use {
                requireNotNull(ComposableReturns.readIndex(it, ComposableReturns.assetHeader))
            }
        }
        val device = ComposableReturns.fromApks(listOf(apk))
        val source = "C:MainActivity.kt#" + kotlin.math.abs("dev.composeinspect.sample".hashCode()).toString(36)
        for (name in listOf("ProbeBoundary", "ConditionalSlot", "NestedSlot")) {
            assertTrue("Expected slot forwarding: $name", device.forwardsSlot(name, source))
        }
        for (name in listOf("NoLayoutWrapper", "ConditionalUi", "InlineWrapper", "ReplacedSlot")) {
            assertTrue("Must retain visual component: $name", !device.forwardsSlot(name, source))
        }
        val field = ComposableReturns::class.java.getDeclaredField("returning").apply { isAccessible = true }
        val expected = field.get(device) as Set<*>
        val actual = field.get(packaged) as Set<*>
        assertTrue(expected.isNotEmpty())
        assertTrue("missing=${expected - actual}; extra=${actual - expected}", expected == actual)
        println("Verified ${actual.size} declarations against the final APK")
    }
}
