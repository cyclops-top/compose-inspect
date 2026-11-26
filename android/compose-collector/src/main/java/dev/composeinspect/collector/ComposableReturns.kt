package dev.composeinspect.collector

import org.jf.dexlib2.dexbacked.DexBackedDexFile
import android.content.Context
import android.util.AtomicFile
import android.util.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.InputStream
import java.io.FileNotFoundException
import java.util.zip.CRC32
import java.util.zip.CheckedInputStream
import java.util.zip.CheckedOutputStream
import java.util.zip.ZipFile
import kotlin.math.abs

/** Declaration keys use the compiler's sourceInfo file and base-36 package hash.
 * Call-site locations belong to the caller, especially for inlined functions.
 */
class ComposableReturns private constructor(private val returning: Set<Declaration>) {
    private data class Declaration(val source: String, val name: String)

    internal fun returnsValue(name: String?, sourceInfo: String?): Boolean {
        if (name.isNullOrEmpty() || sourceInfo == null) return false
        val source = sourceInfo.substringAfterLast(':', "")
        return Declaration(source, name) in returning
    }

    companion object {
        val empty = ComposableReturns(emptySet())
        private const val composer = "Landroidx/compose/runtime/Composer;"
        private val unitReturns = setOf("V", "Lkotlin/Unit;")
        private val dexEntry = Regex("""classes(?:[0-9]+)?\.dex""")

        internal const val assetName = "composeinspect/return-index-v1"
        internal const val assetHeader = "CompScope-returns-v1"

        internal fun readIndex(source: InputStream, key: String): ComposableReturns? {
            val checksum = CRC32()
            val input = DataInputStream(CheckedInputStream(source.buffered(), checksum))
            if (input.readUTF() != key) return null
            val count = input.readInt()
            require(count in 0..200_000)
            val entries = HashSet<Declaration>()
            repeat(count) { entries.add(Declaration(input.readUTF(), input.readUTF())) }
            val calculated = checksum.value
            require(input.readLong() == calculated && input.read() == -1)
            return ComposableReturns(entries)
        }

        /** Restore only an index for this exact installation and indexing algorithm. */
        fun fromInstalledApks(context: Context, paths: List<String>): ComposableReturns {
            // A base-only class index cannot establish coverage of code in other APKs.
            if (paths.size == 1) {
                try {
                    val bundled = context.assets.open(assetName).use { readIndex(it, assetHeader) }
                    if (bundled != null) return bundled
                } catch (_: FileNotFoundException) {
                    // Optional plugin was not applied.
                } catch (e: Exception) {
                    Log.w("ComposeInspect", "Invalid packaged return index", e)
                }
            }
            val cache: AtomicFile
            val key: String
            try {
                cache = AtomicFile(File(context.codeCacheDir, "composeinspect-return-index-v1"))
                val updated = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
                key = paths.joinToString(separator = "\u0000", prefix = "$updated\u0000") {
                    val apk = File(it)
                    "$it:${apk.length()}:${apk.lastModified()}"
                }
            } catch (e: Exception) {
                Log.w("ComposeInspect", "Index cache unavailable", e)
                return fromApks(paths)
            }
            try {
                val cached = cache.openRead().use { readIndex(it, key) }
                if (cached != null) return cached
            } catch (_: FileNotFoundException) {
                // First launch after installation or cache eviction.
            } catch (e: Exception) {
                Log.w("ComposeInspect", "Rebuilding unreadable return index", e)
            }
            val index = fromApks(paths)
            try {
                val stream = cache.startWrite()
                try {
                    val checksum = CRC32()
                    val output = DataOutputStream(CheckedOutputStream(stream.buffered(), checksum))
                    output.writeUTF(key)
                    output.writeInt(index.returning.size)
                    for (entry in index.returning) {
                        output.writeUTF(entry.source)
                        output.writeUTF(entry.name)
                    }
                    output.writeLong(checksum.value)
                    output.flush()
                    cache.finishWrite(stream)
                } catch (e: Exception) {
                    cache.failWrite(stream)
                    throw e
                }
            } catch (e: Exception) {
                Log.w("ComposeInspect", "Could not persist return index", e)
            }
            return index
        }

        /** Read one DEX at a time on a background thread. Never load business classes. */
        fun fromApks(paths: List<String>): ComposableReturns {
            val values = mutableSetOf<Declaration>()
            val veto = mutableSetOf<Declaration>()
            for (path in paths) ZipFile(path).use { apk ->
                for (entry in apk.entries()) {
                    if (!dexEntry.matches(entry.name)) continue
                    val bytes = ByteArray(Math.toIntExact(entry.size))
                    DataInputStream(apk.getInputStream(entry)).use { it.readFully(bytes) }
                    val dex = DexBackedDexFile(null, bytes)
                    val composerType = dex.typeSection.indexOf(composer)
                    if (composerType < 0) continue
                    // Mark Compose prototypes once. Most method IDs can then be skipped
                    // without decoding any class, parameter names, or annotations.
                    val buffer = dex.buffer
                    val signatures = IntArray(dex.protoSection.size)
                    for (index in signatures.indices) {
                        val proto = dex.protoSection.getOffset(index)
                        val args = buffer.readSmallUint(proto + 8)
                        if (args == 0) continue
                        val count = buffer.readSmallUint(args)
                        if ((0 until count).none { buffer.readUshort(args + 4 + it * 2) == composerType }) continue
                        val descriptor = dex.protoSection[index]
                        signatures[index] = if (descriptor.returnType in unitReturns ||
                            "Lkotlin/coroutines/Continuation;" in descriptor.parameterTypes) -1 else 1
                    }
                    val sources = arrayOfNulls<String>(dex.typeSection.size)
                    for (classIndex in dex.classSection.indices) {
                        val type = dex.classSection[classIndex]
                        val file = type.sourceFile ?: continue
                        val pkg = type.type.removePrefix("L").substringBeforeLast('/', "").replace('/', '.')
                        sources[buffer.readSmallUint(dex.classSection.getOffset(classIndex))] = file + "#" + abs(pkg.hashCode()).toString(36)
                    }
                    for (index in dex.methodSection.indices) {
                        // DEX method_id_item: class_idx (ushort), proto_idx (ushort), name_idx.
                        val offset = dex.methodSection.getOffset(index)
                        val category = signatures[buffer.readUshort(offset + 2)]
                        if (category == 0) continue
                        val source = sources[buffer.readUshort(offset)] ?: continue
                        val name = dex.methodSection[index].name.substringBefore('-').substringBefore('$')
                        if (name.isEmpty()) continue
                        val key = Declaration(source, name)
                        if (category > 0) values.add(key) else veto.add(key)
                    }
                }
            }
            // Source information may not distinguish overloads with the same name.
            values.removeAll(veto)
            return ComposableReturns(values)
        }
    }
}
