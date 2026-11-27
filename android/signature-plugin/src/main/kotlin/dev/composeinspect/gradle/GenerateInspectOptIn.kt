package dev.composeinspect.gradle

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

abstract class GenerateInspectOptIn : DefaultTask() {
    @get:OutputDirectory abstract val assets: DirectoryProperty

    @TaskAction fun generate() {
        val marker = assets.file("composeinspect/explicit-opt-in").get().asFile
        marker.parentFile.mkdirs()
        marker.writeText("1")
    }
}
