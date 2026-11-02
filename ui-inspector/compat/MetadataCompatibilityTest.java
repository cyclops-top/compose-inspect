import java.lang.reflect.Proxy;
import kotlin.Metadata;
import deps.ui.inspection.kotlin.metadata.jvm.KotlinClassMetadata;

/** Run with both old and new Kotlin stdlib fixtures to check strict parsing and backward compatibility. */
public final class MetadataCompatibilityTest {
    public static void main(String[] args) {
        Metadata annotation = kotlin.Pair.class.getAnnotation(Metadata.class);
        if (annotation.mv()[0] != 2 || annotation.mv()[1] != Integer.parseInt(args[0])) {
            throw new AssertionError("Wrong fixture metadata version");
        }
        KotlinClassMetadata.Class parsed = (KotlinClassMetadata.Class) KotlinClassMetadata.readStrict(annotation);
        if (!parsed.getKmClass().getName().equals("kotlin/Pair")) throw new AssertionError("Class name lost");
        var properties = parsed.getKmClass().getProperties().stream().map(p -> p.getName()).toList();
        if (!properties.containsAll(java.util.List.of("first", "second"))) throw new AssertionError("Properties lost: " + properties);
        Metadata future = (Metadata) Proxy.newProxyInstance(Metadata.class.getClassLoader(), new Class<?>[]{Metadata.class},
            (proxy, method, values) -> method.getName().equals("mv") ? new int[]{99, 0, 0} : method.invoke(annotation, values));
        try {
            KotlinClassMetadata.readStrict(future);
            throw new AssertionError("Strict version checks were bypassed");
        } catch (IllegalArgumentException expected) { }
        System.out.println("Strict metadata " + java.util.Arrays.toString(annotation.mv()) + ": Pair properties preserved; unsupported future version rejected");
    }
}
