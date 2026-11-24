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
abstract class PrepareBenchmarkFixture : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val fixture: RegularFileProperty

    @get:OutputDirectory
    abstract val assets: DirectoryProperty

    @TaskAction
    fun copyFixture() {
        val directory = assets.get().asFile
        directory.mkdirs()
        fixture.get().asFile.copyTo(directory.resolve("capture.json"), overwrite = true)
    }
}

val benchmarkFixture = providers.gradleProperty("benchmarkJson")
if (benchmarkFixture.isPresent) {
    val prepareFixture = tasks.register<PrepareBenchmarkFixture>("prepareBenchmarkFixture") {
        fixture.set(layout.projectDirectory.file(benchmarkFixture.get()))
    }
    androidComponents.onVariants(androidComponents.selector().withBuildType("debug")) { variant ->
        variant.androidTest?.sources?.assets?.addGeneratedSourceDirectory(prepareFixture, PrepareBenchmarkFixture::assets)
    }
}
