package dev.composeinspect.sdk

import android.app.Application
import android.util.Base64
import dalvik.system.DexClassLoader
import dev.composeinspect.protocol.CollectorEntry
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.util.jar.JarFile
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

/** Confined to the authenticated LocalSocket worker. One live implementation per process. */
internal class CollectorStore(private val app: Application) {
    private val cached get() = File(app.codeCacheDir, "compscope-collector.jar")
    private var active: CollectorEntry? = null
    private var activeDigest: String? = null

    private var activeVersion: String? = null

    fun entry(request: JSONObject): CollectorEntry {
        require(request.optString("digest", activeDigest) == activeDigest) { "Collector version changed" }
        if (request.has("collectorVersion")) require(request.getString("collectorVersion") == activeVersion) { "Collector version changed" }
        return checkNotNull(active) { "Prepare the desktop collector before capture" }
    }

    fun prepare(request: JSONObject): JSONObject {
        val digest = digest(request)
        val expected = expectedVersion(request)
        if (active != null) {
            if (activeVersion != expected || activeDigest != digest) {
                return JSONObject().put("errorCode", "collector_restart_required")
                    .put("error", "采集器更新了。请把设备上正在调试的 App 完全退出，再打开，然后重新抓取。")
            }
            return ready("memory", 0)
        }
        if (cached.isFile && verify(cached, request) && jarVersion(cached) == expected) {
            load(digest, expected)
            return ready("cache", 0)
        }
        return JSONObject().put("state", "missing")
    }

    fun install(request: JSONObject, input: InputStream): JSONObject {
        val digest = digest(request)
        val expected = expectedVersion(request)
        check(active == null) { "Collector already active. Retry capture." }
        val length = request.getInt("length")
        require(length in 1..MAX_BYTES)
        val temp = File.createTempFile("collector-", ".jar", app.codeCacheDir)
        try {
            temp.outputStream().use { output ->
                check(temp.setReadOnly())
                val buffer = ByteArray(64 * 1024)
                var remaining = length
                while (remaining > 0) {
                    val count = input.read(buffer, 0, minOf(remaining, buffer.size))
                    require(count > 0) { "Incomplete collector" }
                    output.write(buffer, 0, count)
                    remaining -= count
                }
            }
            require(verify(temp, request)) { "Collector signature or digest mismatch" }
            val actual = jarVersion(temp)
            require(actual == expected) { "采集器 JAR 版本不匹配：期望 $expected，实际 ${actual ?: "缺少版本"}" }
            android.system.Os.rename(temp.path, cached.path)
            load(digest, expected)
            return ready("installed", length)
        } finally { temp.delete() }
    }

    private fun expectedVersion(request: JSONObject) = request.optString("collectorVersion").also {
        require(it.isNotBlank()) { "缺少采集器版本，请更新桌面端。" }
    }

    private fun jarVersion(file: File): String? = JarFile(file).use {
        it.manifest?.mainAttributes?.getValue("Implementation-Version")
    }

    private fun digest(request: JSONObject): String {
        require(request.getInt("collectorABI") == 1 && request.getInt("pid") == android.os.Process.myPid())
        return request.getString("digest").also { require(it.matches(Regex("[0-9a-f]{64}"))) }
    }

    private fun verify(file: File, request: JSONObject): Boolean {
        if (file.length() !in 1L..MAX_BYTES.toLong()) return false
        val key = app.assets.open("composeinspect/collector-public.der").use { it.readBytes() }
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initVerify(KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(key)))
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
                signature.update(buffer, 0, count)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it) } == request.getString("digest") &&
            signature.verify(Base64.decode(request.getString("signature"), Base64.DEFAULT))
    }

    private fun load(digest: String, version: String) {
        val loader = DexClassLoader(cached.path, app.codeCacheDir.path, null, app.classLoader)
        val type = loader.loadClass("dev.composeinspect.payload.DesktopCollector")
        check(type.classLoader === loader)
        active = type.getConstructor(Application::class.java).newInstance(app) as CollectorEntry
        activeDigest = digest
        activeVersion = version
    }

    private fun ready(state: String, bytes: Int) = JSONObject().put("state", state)
        .put("collectorVersion", activeVersion).put("digest", activeDigest).put("transferredBytes", bytes)
        .put("capabilities", JSONArray(checkNotNull(active).capabilities()))

    private companion object { const val MAX_BYTES = 16 * 1024 * 1024 }
}
