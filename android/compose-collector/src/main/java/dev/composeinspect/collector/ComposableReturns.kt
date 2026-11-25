package dev.composeinspect.collector

import org.jf.dexlib2.dexbacked.DexBackedDexFile
import java.io.DataInputStream
import java.util.zip.ZipFile
import kotlin.math.abs

/** Declaration keys use the compiler's sourceInfo file and base-36 package hash.
 * Call-site locations belong to the caller, especially for inlined functions.
 */
class ComposableReturns private constructor(private val returning: Set<Declaration>) {
    private data class Declaration(val source: String, val name: String)

    internal fun returnsValue(name: String?, sourceInfo: String?): Boolean {
        if (name == null || sourceInfo == null) return false
        val source = sourceInfo.substringAfterLast(':', "")
        return Declaration(source, name) in returning
    }

    companion object {
        val empty = ComposableReturns(emptySet())
        private const val composer = "Landroidx/compose/runtime/Composer;"
        private val unitReturns = setOf("V", "Lkotlin/Unit;")
        private val dexEntry = Regex("""classes(?:[0-9]+)?\.dex""")

        /** Read one DEX at a time on the SDK socket thread. Never load business classes. */
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
