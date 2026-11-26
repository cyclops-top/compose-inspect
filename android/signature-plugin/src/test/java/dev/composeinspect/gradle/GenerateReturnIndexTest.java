package dev.composeinspect.gradle;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.Assert.assertEquals;

public class GenerateReturnIndexTest {
    @Rule public TemporaryFolder temp = new TemporaryFolder();

    private Path fixture(String owner, String returnType) throws Exception {
        var cls = new ClassWriter(0);
        cls.visit(Opcodes.V17, Opcodes.ACC_PUBLIC | Opcodes.ACC_ABSTRACT, "app/" + owner, null, "java/lang/Object", null);
        cls.visitSource("Widgets.kt", null);
        cls.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_ABSTRACT, "label-mangled",
                "(Landroidx/compose/runtime/Composer;I)" + returnType, null, null).visitEnd();
        cls.visitEnd();
        Path path = temp.newFile(owner + ".jar").toPath();
        try (var out = new ZipOutputStream(Files.newOutputStream(path))) {
            out.putNextEntry(new ZipEntry("app/" + owner + ".class"));
            out.write(cls.toByteArray());
            out.closeEntry();
        }
        return path;
    }

    @Test public void cachedDependencyVetoSurvivesMergeOrder() throws Exception {
        Path value = fixture("Value", "I");
        Path unit = fixture("Ui", "V");
        Path dir = temp.getRoot().toPath();
        var key = new GenerateReturnIndex.Key("Widgets.kt#" + Integer.toString("app".hashCode(), 36), "label");
        var entries = new HashMap<GenerateReturnIndex.Key, Boolean>();
        GenerateReturnIndex.mergeJar(value, dir.resolve("a"), entries);
        assertEquals(Boolean.TRUE, entries.get(key));
        GenerateReturnIndex.mergeJar(unit, dir.resolve("b"), entries);
        assertEquals(Boolean.FALSE, entries.get(key));
        entries.clear();
        GenerateReturnIndex.mergeJar(unit, dir.resolve("b"), entries);
        GenerateReturnIndex.mergeJar(value, dir.resolve("a"), entries);
        assertEquals(Boolean.FALSE, entries.get(key));
    }
}
