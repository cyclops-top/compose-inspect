package dev.composeinspect.gradle

import com.android.build.api.dsl.ApplicationBuildType
import org.gradle.api.plugins.ExtensionAware

private const val enabledKey = "dev.composeinspect.enabled"

var ApplicationBuildType.composeInspect: Boolean
    get() {
        val extras = (this as ExtensionAware).extensions.extraProperties
        return if (extras.has(enabledKey)) extras.get(enabledKey) as Boolean else name == "debug"
    }
    set(value) {
        (this as ExtensionAware).extensions.extraProperties.set(enabledKey, value)
    }
