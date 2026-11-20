plugins { id("com.android.library") }
android {
    namespace = "dev.composeinspect.protocol"
    compileSdk = 37
    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "dev.composeinspect.protocol.EncodingBenchmark"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")

}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

// The optional real-device fixture stays in build/, never in the published library or sources.
val prepareBenchmarkFixture by tasks.registering(Copy::class) {
    val fixture = providers.gradleProperty("benchmarkJson")
    onlyIf { fixture.isPresent }
    from(fixture)
    into(layout.buildDirectory.dir("benchmark-assets"))
    rename { "capture.json" }
}
tasks.matching { it.name == "mergeDebugAndroidTestAssets" }.configureEach { dependsOn(prepareBenchmarkFixture) }

androidComponents {
    onVariants { variant ->
        variant.androidTest?.sources?.assets?.addStaticSourceDirectory(layout.buildDirectory.dir("benchmark-assets").get().asFile.path)
    }
}
