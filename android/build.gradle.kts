import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.SourcesJar
import com.vanniktech.maven.publish.MavenPublishBaseExtension

plugins {
    id("com.vanniktech.maven.publish") version "0.37.0" apply false
    id("com.android.library") version "9.2.1" apply false
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
}

val sdkArtifacts = mapOf(
    "inspector-sdk" to "compose-inspector",
    "compose-collector" to "compose-inspector-collector",
    "protocol" to "compose-inspector-protocol",
)
subprojects {
    val artifact = sdkArtifacts[name] ?: return@subprojects
    group = "top.cyclops"
    version = providers.gradleProperty("sdkVersion").get()
    plugins.withId("com.android.library") {
        apply(plugin = "com.vanniktech.maven.publish")
        apply(from = rootProject.file("gradle/reposilite.gradle.kts"))
        extensions.configure<MavenPublishBaseExtension> {
            configure(AndroidSingleVariantLibrary(
                variant = "release", sourcesJar = SourcesJar.Sources(), javadocJar = JavadocJar.Empty(),
            ))
            coordinates("top.cyclops", artifact, project.version.toString())
            pom {
                name.set(artifact)
                description.set("Debug-only Compose UI inspection: hierarchy, parameters and source locations.")
                url.set("https://www.cyclops.top")
                licenses {
                    license {
                        name.set("Apache-2.0")
                        url.set("https://spdx.org/licenses/Apache-2.0.html")
                    }
                }
                developers {
                    developer {
                        id.set("cyclops-top")
                        name.set("Justin cheng")
                        url.set("https://www.cyclops.top")
                    }
                }
                // Supply the actual private repository URL when it has been created.
                val repositoryUrl = providers.gradleProperty("sdkScmUrl")
                if (repositoryUrl.isPresent) {
                    scm {
                        url.set(repositoryUrl)
                        connection.set(repositoryUrl.map { "scm:git:$it.git" })
                        developerConnection.set(repositoryUrl.map { "scm:git:$it.git" })
                    }
                }
            }
        }
    }
}
