/* Copyright 2026 The Android Open Source Project. Licensed under the Apache License, Version 2.0. */
package com.android.tools.ui.inspector.client

import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.security.MessageDigest

/** Exact-version repair: keep the Compose inspector protocol and update only its isolated metadata reader. */
internal object ComposeInspectorCompatibility {
  private const val FILE = "compose-1.12.1-metadata-2.4.21.jar"
  private const val SHA256 = "86fc26e2e3735e313576b9ab37f6ae2a1e05dd8cfa308fd5710c93779f622353"
  private const val RESOURCE = "/tools/base/ui-inspector/core/compat/$FILE"

  fun resolve(version: String, cacheDir: Path): Path? {
    if (version != "1.12.1") return null
    val bytes = javaClass.getResourceAsStream(RESOURCE)?.use { it.readBytes() }
      ?: throw IOException("Missing bundled Compose $version metadata compatibility inspector")
    if (digest(bytes) != SHA256) throw IOException("Bundled Compose metadata compatibility inspector checksum mismatch")
    Files.createDirectories(cacheDir)
    // A different path also prevents the device's inspector class-loader cache from reusing the original library.
    val target = cacheDir.resolve(FILE)
    if (Files.isRegularFile(target) && digest(Files.readAllBytes(target)) == SHA256) return target
    val temporary = Files.createTempFile(cacheDir, ".metadata-compat-", ".jar")
    try {
      Files.write(temporary, bytes)
      Files.move(temporary, target, ATOMIC_MOVE, REPLACE_EXISTING)
    } finally {
      Files.deleteIfExists(temporary)
    }
    return target
  }

  private fun digest(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
