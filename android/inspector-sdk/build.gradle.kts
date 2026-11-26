plugins { id("com.android.library") }
android {
    namespace = "dev.composeinspect.inspector.sdk"
    compileSdk = 37
    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    implementation("androidx.startup:startup-runtime:1.1.1")
    implementation(project(":protocol"))
    compileOnly("androidx.compose.ui:ui:${providers.gradleProperty("composeVersion").getOrElse("1.12.1")}")
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
