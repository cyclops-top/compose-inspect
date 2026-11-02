import java.nio.file.*;
import java.util.*;
import java.util.jar.*;
import java.io.*;
import org.objectweb.asm.*;
import org.objectweb.asm.commons.*;
import org.jf.dexlib2.*;
import org.jf.dexlib2.iface.*;
import org.jf.dexlib2.immutable.*;
import org.jf.dexlib2.writer.pool.DexPool;

/** Build-time replacement of only the inspector's relocated metadata library. */
public final class UpgradeMetadata {
    static final String PREFIX = "deps/ui/inspection/";
    static final String METADATA = "Ldeps/ui/inspection/kotlin/metadata/";
    public static void main(String[] args) throws Exception {
        Path inspector = Path.of(args[0]), metadata = Path.of(args[1]), out = Path.of(args[2]);
        Files.createDirectories(out);
        try (JarFile jar = new JarFile(inspector.toFile())) {
            Files.copy(jar.getInputStream(jar.getJarEntry("classes.dex")), out.resolve("original.dex"), StandardCopyOption.REPLACE_EXISTING);
        }
        DexFile dex = DexFileFactory.loadDexFile(out.resolve("original.dex").toFile(), OpcodesForDex());
        var retained = new ArrayList<ClassDef>();
        int removed = 0;
        for (ClassDef cls : dex.getClasses()) {
            if (cls.getType().startsWith(METADATA)) removed++;
            else retained.add(cls);
        }
        if (removed < 100) throw new IllegalStateException("Expected relocated metadata classes, found " + removed);
        DexPool.writeTo(out.resolve("inspector.dex").toString(), new ImmutableDexFile(dex.getOpcodes(), retained));
        Remapper remapper = new Remapper(org.objectweb.asm.Opcodes.ASM9) {
            @Override public String map(String name) {
                return name.startsWith("kotlin/metadata/") ? PREFIX + name : name;
            }
        };
        try (JarFile jar = new JarFile(metadata.toFile()); JarOutputStream target = new JarOutputStream(Files.newOutputStream(out.resolve("metadata-shaded.jar")))) {
            for (JarEntry entry : Collections.list(jar.entries())) {
                if (!entry.getName().endsWith(".class")) continue;
                ClassReader reader = new ClassReader(jar.getInputStream(entry));
                ClassWriter writer = new ClassWriter(0);
                reader.accept(new ClassRemapper(writer, remapper), 0);
                target.putNextEntry(new JarEntry(remapper.map(reader.getClassName()) + ".class"));
                target.write(writer.toByteArray());
                target.closeEntry();
            }
        }
        System.out.println("Retained " + retained.size() + " inspector classes; replacing " + removed + " metadata classes");
    }
    static org.jf.dexlib2.Opcodes OpcodesForDex() { return org.jf.dexlib2.Opcodes.forApi(26); }
}
