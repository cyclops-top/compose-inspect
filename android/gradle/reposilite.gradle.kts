import org.gradle.api.credentials.PasswordCredentials
import org.gradle.api.publish.PublishingExtension
import org.gradle.authentication.http.BasicAuthentication

extensions.configure<PublishingExtension> {
    repositories.maven {
        name = "reposilite"
        val repository = if (project.version.toString().endsWith("-SNAPSHOT")) "snapshots" else "releases"
        url = uri("https://repo.tick-tick.cn/$repository")
        credentials(PasswordCredentials::class)
        authentication { create<BasicAuthentication>("basic") }
    }
}
