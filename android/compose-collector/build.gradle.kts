plugins { id("com.android.library") }
android {
    namespace = "dev.composeinspect.compose.collector"
    compileSdk = 37
    defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
val composeVersion = providers.gradleProperty("composeVersion").getOrElse("1.12.1")

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    implementation("androidx.compose.foundation:foundation:$composeVersion")
    implementation(project(":protocol"))
    implementation("org.smali:dexlib2:2.5.2")
    implementation("androidx.compose.ui:ui-tooling-data:$composeVersion")
    implementation("androidx.compose.ui:ui:$composeVersion")
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

tasks.withType<Test>().configureEach {
    providers.environmentVariable("COMPOSEINSPECT_INDEX_APK").orNull?.let { apk ->
        inputs.file(apk).withPropertyName("indexParityApk").withPathSensitivity(PathSensitivity.NONE)
    }
}
