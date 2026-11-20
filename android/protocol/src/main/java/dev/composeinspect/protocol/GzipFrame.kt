package dev.composeinspect.protocol

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.util.zip.Deflater
import java.util.zip.GZIPOutputStream

/** Negotiated gzip-json-v1: 4-byte network-order compressed length followed by one gzip member. */
object GzipFrame {
    fun encode(json: ByteArray): ByteArray {
        val buffer = ByteArrayOutputStream()
        object : GZIPOutputStream(buffer, 65536) {
            init { def.setLevel(Deflater.BEST_SPEED) }
        }.use { it.write(json) }
        val compressed = buffer.toByteArray()
        return ByteArrayOutputStream(compressed.size + 4).also { framed ->
            DataOutputStream(framed).use {
                it.writeInt(compressed.size)
                it.write(compressed)
            }
        }.toByteArray()
    }
}
