package dev.composeinspect.gradle;

import com.android.build.api.artifact.ScopedArtifact;
import com.android.build.api.dsl.ApplicationExtension;
import com.android.build.api.variant.ApplicationAndroidComponentsExtension;
import com.android.build.api.variant.ApplicationVariant;
import com.android.build.api.variant.ScopedArtifacts;
import org.gradle.api.Action;
import org.gradle.api.GradleException;
import org.gradle.api.Plugin;
import org.gradle.api.Project;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;

public class SignaturePlugin implements Plugin<Project> {
    @Override public void apply(Project project) {
        project.getPluginManager().withPlugin("com.android.application", ignored -> {
            var android = project.getExtensions().getByType(ApplicationAndroidComponentsExtension.class);
            var enabledTypes = new HashSet<String>();
            android.finalizeDsl((Action<ApplicationExtension>) app -> {
                for (var buildType : app.getBuildTypes()) {
                    if (!ComposeInspectBuildTypeKt.getComposeInspect(buildType)) continue;
                    String type = buildType.getName();
                    enabledTypes.add(type);
                    String configuration = type + "Implementation";
                    project.getConfigurations().named(name -> name.equals(configuration)).configureEach(config ->
                            project.getDependencies().add(config.getName(), "top.cyclops:compose-inspector:" + sdkVersion()));
                }
            });
            android.onVariants(android.selector().all(), (Action<ApplicationVariant>) variant -> {
                if (!enabledTypes.contains(variant.getBuildType())) return;
                var app = project.getExtensions().getByType(ApplicationExtension.class);
                if (variant.isMinifyEnabled() || !app.getDynamicFeatures().isEmpty()) return;
                String name = variant.getName();
                var task = project.getTasks().register("generate" + Character.toUpperCase(name.charAt(0))
                        + name.substring(1) + "ComposeReturnIndex", GenerateReturnIndex.class, index ->
                    index.getJarCache().set(project.getLayout().getBuildDirectory().dir("intermediates/composeReturnIndex/" + name)));
                variant.getArtifacts().forScope(ScopedArtifacts.Scope.ALL).use(task)
                        .toGet(ScopedArtifact.CLASSES.INSTANCE, GenerateReturnIndex::getJars, GenerateReturnIndex::getDirs);
                variant.getSources().getAssets().addGeneratedSourceDirectory(task, GenerateReturnIndex::getAssets);
            });
        });
    }

    private static String sdkVersion() {
        try (var resource = SignaturePlugin.class.getResourceAsStream("sdk-version.txt")) {
            if (resource == null) throw new GradleException("CompScope plugin is missing sdk-version.txt");
            return new String(resource.readAllBytes(), StandardCharsets.UTF_8).trim();
        } catch (IOException error) {
            throw new GradleException("Could not read the CompScope SDK version", error);
        }
    }
}
