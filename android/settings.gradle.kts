pluginManagement { includeBuild("signature-plugin"); repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "ComposeInspectAndroid"
include(":protocol", ":compose-collector", ":inspector-sdk", ":sample")
