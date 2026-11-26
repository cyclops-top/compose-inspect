package dev.composeinspect.gradle;

import org.gradle.api.DefaultTask;
import org.gradle.api.file.Directory;
import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.file.RegularFile;
import org.gradle.api.provider.ListProperty;
import org.gradle.api.tasks.*;
import org.objectweb.asm.*;

import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.security.DigestInputStream;
import java.util.*;
import java.util.zip.*;

@CacheableTask
public abstract class GenerateReturnIndex extends DefaultTask {
    @Classpath public abstract ListProperty<RegularFile> getJars();
    @Classpath public abstract ListProperty<Directory> getDirs();
    @LocalState public abstract DirectoryProperty getJarCache();
    @OutputDirectory public abstract DirectoryProperty getAssets();

    private static final String COMPOSER = "Landroidx/compose/runtime/Composer;";
    private static final Type CONTINUATION = Type.getObjectType("kotlin/coroutines/Continuation");
    record Key(String source, String name) implements Comparable<Key> {
        @Override public int compareTo(Key other) {
            int order = source.compareTo(other.source);
            return order != 0 ? order : name.compareTo(other.name);
        }
    }

    private static void scan(InputStream input, Map<Key, Boolean> result) throws IOException {
        new ClassReader(input).accept(new ClassVisitor(Opcodes.ASM9) {
            private String suffix;
            private String source;
            @Override public void visit(int v, int a, String owner, String sig, String parent, String[] interfaces) {
                int slash = owner.lastIndexOf('/');
                String pkg = slash < 0 ? "" : owner.substring(0, slash).replace('/', '.');
                suffix = "#" + Integer.toString(Math.abs(pkg.hashCode()), 36);
            }
            @Override public void visitSource(String file, String debug) {
                if (file != null) source = file + suffix;
            }
            @Override public MethodVisitor visitMethod(int access, String name, String desc, String sig, String[] exceptions) {
                if (source == null || !desc.contains(COMPOSER)) return null;
                List<Type> args = Arrays.asList(Type.getArgumentTypes(desc));
                if (!args.contains(Type.getType(COMPOSER))) return null;
                String type = Type.getReturnType(desc).getDescriptor();
                boolean returns = !type.equals("V") && !type.equals("Lkotlin/Unit;") && !args.contains(CONTINUATION);
                int end = name.length();
                for (char sep : new char[]{'-', '$'}) {
                    int at = name.indexOf(sep);
                    if (at >= 0) end = Math.min(end, at);
                }
                if (end == 0) return null;
                result.merge(new Key(source, name.substring(0, end)), returns, (a,b) -> a && b);
                return null;
            }
        }, ClassReader.SKIP_CODE | ClassReader.SKIP_FRAMES);
    }

    private static String digest(Path jar) throws Exception {
        var hash = MessageDigest.getInstance("SHA-256");
        try (var in = new DigestInputStream(Files.newInputStream(jar), hash)) {
            in.transferTo(OutputStream.nullOutputStream());
        }
        return HexFormat.of().formatHex(hash.digest());
    }

    static void mergeJar(Path path, Path shard, Map<Key, Boolean> result) throws IOException {
        if (!Files.exists(shard)) {
            var local = new TreeMap<Key, Boolean>();
            try (var jar = new ZipFile(path.toFile())) {
                for (var entries = jar.entries(); entries.hasMoreElements();) {
                    var entry = entries.nextElement();
                    if (!entry.getName().endsWith(".class") || entry.getName().startsWith("META-INF/")) continue;
                    try (var input = jar.getInputStream(entry)) { scan(input, local); }
                }
            }
            Path temp = Files.createTempFile(shard.getParent(), "shard-", ".tmp");
            try {
                try (var out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(temp)))) {
                    out.writeInt(local.size());
                    for (var entry : local.entrySet()) {
                        out.writeUTF(entry.getKey().source());
                        out.writeUTF(entry.getKey().name());
                        out.writeBoolean(entry.getValue());
                    }
                }
                Files.move(temp, shard, StandardCopyOption.REPLACE_EXISTING);
            } finally { Files.deleteIfExists(temp); }
        }
        try (var in = new DataInputStream(new BufferedInputStream(Files.newInputStream(shard)))) {
            for (int n = in.readInt(); n > 0; n--)
                result.merge(new Key(in.readUTF(), in.readUTF()), in.readBoolean(), (a,b) -> a && b);
        }
    }

    @TaskAction public void generate() throws Exception {
        var entries = new TreeMap<Key, Boolean>();
        Path cache = getJarCache().get().getAsFile().toPath();
        Files.createDirectories(cache);
        var used = new HashSet<Path>();
        for (RegularFile file : getJars().get()) {
            Path path = file.getAsFile().toPath();
            // Bump the shard version whenever bytecode classification changes.
            Path shard = cache.resolve("v2-" + digest(path));
            used.add(shard);
            mergeJar(path, shard, entries);
        }
        try (var all = Files.list(cache)) {
            for (var path : all.toList()) if (!used.contains(path)) Files.delete(path);
        }
        for (Directory dir : getDirs().get()) {
            Path directory = dir.getAsFile().toPath();
            if (!Files.isDirectory(directory)) continue;
            try (var files = Files.walk(directory)) {
                for (var file : files.filter(p -> p.toString().endsWith(".class")).toList()) {
                    try (var input = Files.newInputStream(file)) { scan(input, entries); }
                }
            }
        }
        entries.values().removeIf(v -> !v);
        Path index = getAssets().get().getAsFile().toPath().resolve("composeinspect/return-index-v1");
        Files.createDirectories(index.getParent());
        CRC32 crc = new CRC32();
        try (var out = new DataOutputStream(new CheckedOutputStream(new BufferedOutputStream(Files.newOutputStream(index)), crc))) {
            out.writeUTF("CompScope-returns-v1");
            out.writeInt(entries.size());
            for (var key : entries.keySet()) {
                out.writeUTF(key.source());
                out.writeUTF(key.name());
            }
            out.writeLong(crc.getValue());
        }
    }
}
