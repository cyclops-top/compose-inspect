package dev.composeinspect.protocol

import android.app.Activity
import org.json.JSONObject

/** Loader ABI 1. Activity collection is accessed on the main thread only. */
interface CollectorEntry {
    fun capture(activities: Collection<Activity>, options: JSONObject, attachments: MutableList<ByteArray>): JSONObject
    fun capabilities(): List<String>
}
