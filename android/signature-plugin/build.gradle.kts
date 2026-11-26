import java.util.Properties
plugins {
    `embedded-kotlin`
    `java-gradle-plugin`
    `maven-publish`
}

group = "top.cyclops"
val sdkProperties = Properties()
file("../gradle.properties").inputStream().use { sdkProperties.load(it) }
version = providers.gradleProperty("sdkVersion").getOrElse(sdkProperties.getProperty("sdkVersion"))
apply(from = file("../gradle/reposilite.gradle.kts"))
java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

tasks.processResources {
    val sdkVersion = project.version.toString()
    inputs.property("sdkVersion", sdkVersion)
    filesMatching("dev/composeinspect/gradle/sdk-version.txt") {
        expand(mapOf("sdkVersion" to sdkVersion))
    }
}

dependencies {
    compileOnly("com.android.tools.build:gradle-api:9.2.1")
    implementation("org.ow2.asm:asm:9.9.1")
    testImplementation("junit:junit:4.13.2")
}
gradlePlugin {
    plugins.create("composeInspectSignatures") {
        id = "top.cyclops.compose-inspector"
        implementationClass = "dev.composeinspect.gradle.SignaturePlugin"
        displayName = "CompScope Compose signature index"
        description = "Packages a precomputed Compose declaration index in debug applications."
    }
}
