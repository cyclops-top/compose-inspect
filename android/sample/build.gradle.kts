plugins {
    id("com.android.application")
    id("top.cyclops.compose-inspector")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "dev.composeinspect.sample"
    compileSdk = 37
    defaultConfig {
        applicationId = "dev.composeinspect.sample"
        minSdk = 26
        targetSdk = 36
        testInstrumentationRunner = "dev.composeinspect.sample.SemanticsReadBenchmark"
        versionCode = 1
        versionName = "0.1"
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
val composeVersion = providers.gradleProperty("composeVersion").getOrElse("1.12.1")

// Exercise the plugin's published coordinate against the SDK in this checkout.
configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
        substitute(module("top.cyclops:compose-inspector")).using(project(":inspector-sdk"))
    }
}

dependencies {
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation:$composeVersion")
    androidTestImplementation(project(":compose-collector"))
    androidTestImplementation(project(":protocol"))
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
