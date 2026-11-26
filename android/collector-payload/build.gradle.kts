plugins { id("com.android.application") }
android {
    namespace = "dev.composeinspect.payload"
    compileSdk = 37
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
val composeVersion = providers.gradleProperty("composeVersion").getOrElse("1.12.1")
dependencies {
    implementation(project(":compose-collector")) { isTransitive = false }
    implementation("androidx.compose.ui:ui-tooling-data-android:$composeVersion") { isTransitive = false }
    implementation("org.smali:dexlib2:2.5.2")
    compileOnly(project(":protocol"))
    compileOnly("androidx.compose.foundation:foundation:$composeVersion")
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
