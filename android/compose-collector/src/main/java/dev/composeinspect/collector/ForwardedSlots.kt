package dev.composeinspect.collector

import org.jf.dexlib2.AccessFlags
import org.jf.dexlib2.ReferenceType
import org.jf.dexlib2.dexbacked.DexBackedDexFile
import org.jf.dexlib2.dexbacked.instruction.DexBackedInstruction
import org.jf.dexlib2.Opcode
import org.jf.dexlib2.iface.Method
import org.jf.dexlib2.iface.instruction.*
import org.jf.dexlib2.iface.reference.MethodReference

/** Prove forwarding from compiled Kotlin declarations, including branches absent in a capture. */
internal class ForwardedSlots {
    private val dependencies = mutableMapOf<String, Set<String>>()
    private val declarations = mutableMapOf<ComposableReturns.Declaration, MutableList<String>>()
    private val ambiguous = mutableSetOf<ComposableReturns.Declaration>()

    fun veto(key: ComposableReturns.Declaration) { ambiguous.add(key) }

    fun inspect(method: Method, source: String, targets: InvokeTargets) {
        if (AccessFlags.SYNTHETIC.isSet(method.accessFlags) || "\$lambda\$" in method.name) return
        val key = ComposableReturns.Declaration(source, method.name.substringBefore('-').substringBefore('$'))
        if (key in ambiguous) return
        val calls = forwardingCalls(method, targets)
        if (calls == null) {
            ambiguous += key
        } else {
            val id = method.toString()
            dependencies[id] = calls
            declarations.getOrPut(key) { mutableListOf() }.add(id)
        }
    }

    fun resolve(): Set<ComposableReturns.Declaration> {
        val proven = mutableSetOf<String>()
        do {
            val before = proven.size
            for ((id, calls) in dependencies) if (calls.all(proven::contains)) proven.add(id)
        } while (proven.size != before)
        return declarations.filter { (key, methods) -> key !in ambiguous && methods.all(proven::contains) }.keys.toSet()
    }

    private fun forwardingCalls(method: Method, targets: InvokeTargets): Set<String>? {
        val args = method.parameterTypes
        if (method.returnType != "V" || args.count { it == SLOT } != 1) return null
        val body = method.implementation ?: return null
        val slot = body.registerCount - args.drop(args.indexOf(SLOT)).sumOf(::width)
        // A register is trusted only if every definition is a copy of the incoming slot.
        // This works across jumps and handlers without guessing which branch was active.
        val sources = mutableMapOf<Int, MutableSet<Int>>()
        val firstArg = body.registerCount - args.sumOf(::width) - if (AccessFlags.STATIC.isSet(method.accessFlags)) 0 else 1
        for (reg in firstArg until body.registerCount) if (reg != slot) sources[reg] = mutableSetOf(-1)
        val forwardedRegisters = mutableSetOf<Int>()
        val calls = mutableSetOf<String>()
        for (insn in body.instructions) {
            if (insn.opcode.setsRegister() && insn.opcode != Opcode.CHECK_CAST) {
                val dest = (insn as OneRegisterInstruction).registerA
                val from = if (insn.opcode in moves) (insn as TwoRegisterInstruction).registerB else -1
                sources.getOrPut(dest) { mutableSetOf() }.add(from)
                if (insn.opcode.setsWideRegister()) sources.getOrPut(dest + 1) { mutableSetOf() }.add(-1)
            }
            if (insn.opcode.name.startsWith("invoke", ignoreCase = true)) {
                val target = targets.lookup(insn) ?: return null
                if (target === ignored) continue
                if (target.requiresStatic && insn.opcode !in statics) return null
                forwardedRegisters.add(register(insn, target.position) ?: return null)
                target.dependency?.let(calls::add)
            }
        }
        val trusted = mutableSetOf<Int>()
        if (slot !in sources) trusted.add(slot)
        do {
            val before = trusted.size
            for ((dest, defs) in sources) if (defs.all(trusted::contains)) trusted.add(dest)
        } while (trusted.size != before)

        return if (forwardedRegisters.isNotEmpty() && trusted.containsAll(forwardedRegisters)) calls else null
    }

    internal class Target(val position: Int, val requiresStatic: Boolean = false, val dependency: String? = null)

    /** Invoke instructions share method IDs within one DEX. Decode each target signature once. */
    internal class InvokeTargets(private val dex: DexBackedDexFile) {
        private val cache = arrayOfNulls<Target>(dex.methodSection.size)
        fun lookup(insn: Instruction): Target? {
            if (insn.opcode.referenceType != ReferenceType.METHOD) return null
            val offset = (insn as DexBackedInstruction).instructionStart
            val id = dex.dataBuffer.readUshort(offset + 2)
            val target = cache[id] ?: classify(dex.methodSection[id]).also { cache[id] = it }
            return target.takeUnless { it === rejected }
        }

        private fun classify(target: MethodReference): Target {
            val owner = target.definingClass
            val name = target.name
            if (owner == SLOT && name == "invoke") return slotReceiver
            if (owner.startsWith("Lkotlin/jvm/functions/Function") && name == "invoke") return rejected
            if (owner == COMPOSER) return if (name in composerBookkeeping) ignored else rejected
            val params = target.parameterTypes
            if (COMPOSER !in params ||
                owner == "Landroidx/compose/runtime/ComposerKt;" && name in markers ||
                owner == "Landroidx/compose/runtime/SnapshotStateKt;" && name == "collectAsState") return ignored
            if (params.count { it == SLOT } != 1) return rejected
            val slotPosition = params.take(params.indexOf(SLOT)).sumOf(::width)
            val provider = owner == "Landroidx/compose/runtime/CompositionLocalKt;" && name == "CompositionLocalProvider"
            return Target(slotPosition, true, if (provider) null else target.toString())
        }
    }

    private fun register(insn: Instruction, index: Int): Int? = when (insn) {
        is RegisterRangeInstruction -> if (index < insn.registerCount) insn.startRegister + index else null
        is FiveRegisterInstruction -> listOf(insn.registerC, insn.registerD, insn.registerE, insn.registerF, insn.registerG).getOrNull(index)
        else -> null
    }

    private companion object {
        val ignored = Target(-1)
        val rejected = Target(-1)
        val slotReceiver = Target(0)
        const val COMPOSER = "Landroidx/compose/runtime/Composer;"
        const val SLOT = "Lkotlin/jvm/functions/Function2;"
        fun width(type: CharSequence) = if (type == "J" || type == "D") 2 else 1
        val moves = setOf(Opcode.MOVE_OBJECT, Opcode.MOVE_OBJECT_FROM16, Opcode.MOVE_OBJECT_16)
        val statics = setOf(Opcode.INVOKE_STATIC, Opcode.INVOKE_STATIC_RANGE)
        val markers = setOf("sourceInformation", "sourceInformationMarkerStart", "sourceInformationMarkerEnd")
        val composerBookkeeping = setOf("startRestartGroup", "endRestartGroup", "startReplaceGroup", "endReplaceGroup",
            "startReplaceableGroup", "endReplaceableGroup", "changed", "changedInstance", "getSkipping", "skipToGroupEnd",
            "shouldExecute", "rememberedValue", "updateRememberedValue", "consume", "getDefaultsInvalid", "startDefaults", "endDefaults")
    }
}
