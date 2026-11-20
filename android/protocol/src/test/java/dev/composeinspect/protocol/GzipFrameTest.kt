package dev.composeinspect.protocol

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.util.zip.GZIPInputStream

class GzipFrameTest {
    @Test fun framingPreservesUtf8AndExactJsonBytes() {
        val json = "{\"text\":\"中文 😀\",\"value\":9007199254740993}\n".toByteArray(Charsets.UTF_8)
        val frame = GzipFrame.encode(json)
        val input = DataInputStream(ByteArrayInputStream(frame))
        assertEquals(frame.size - 4, input.readInt())
        assertArrayEquals(json, GZIPInputStream(input).use { it.readBytes() })
    }
}
