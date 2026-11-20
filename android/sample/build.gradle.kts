plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "dev.composeinspect.sample"
    compileSdk = 37
    defaultConfig {
        applicationId = "dev.composeinspect.sample"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
val composeVersion = providers.gradleProperty("composeVersion").getOrElse("1.12.1")

dependencies {
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation:$composeVersion")
    // The only SDK integration. The baseline build uses the identical business sources.
    if (providers.gradleProperty("withInspectorSdk").orNull != "false") {
        debugImplementation(project(":inspector-sdk"))
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

// Records the actually resolved versions; a requested version alone is not evidence.
tasks.register("composeDependencyReport") {
    doLast {
        for (name in listOf("debugRuntimeClasspath", "releaseRuntimeClasspath")) {
            configurations.getByName(name).incoming.resolutionResult.allComponents
                .mapNotNull { it.moduleVersion }.distinct().filter { it.group.startsWith("androidx.compose") }
                .sortedBy { it.toString() }.forEach { println("COMPOSE_DEPENDENCY $name $it") }
        }
    }
}
