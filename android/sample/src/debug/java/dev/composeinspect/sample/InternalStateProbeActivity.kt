package dev.composeinspect.sample

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** Debug research fixture. Readers are instance-scoped and only run on a manual sample. */
class InternalStateProbeActivity : ComponentActivity() {
    private val readers = mutableMapOf<String, () -> Boolean>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val register = intent.getBooleanExtra("register", false)
        setContent {
            var showFirst by remember { mutableStateOf(true) }
            Column(Modifier.padding(32.dp)) {
                for (instance in listOf("A", "B")) {
                    if (instance == "B" || showFirst) key(instance) { HiddenFlag(instance, register) }
                }
                BasicText("Sample", Modifier.clickable {
                    Log.i("CompScopeStateProbe", readers.entries.joinToString(prefix = "readers=[", postfix = "]") {
                        "${it.key}=${it.value()}"
                    })
                }.padding(12.dp))
                BasicText("Remove A", Modifier.clickable { showFirst = false }.padding(12.dp))
            }
        }
    }

    @Composable
    private fun HiddenFlag(instance: String, register: Boolean) {
        val hiddenFlag = remember { mutableStateOf(false) }
        if (register) DisposableEffect(instance) {
            readers[instance] = { hiddenFlag.value }
            onDispose { readers.remove(instance) }
        }
        BasicText("Toggle " + instance, Modifier.clickable {
            hiddenFlag.value = !hiddenFlag.value
        }.padding(12.dp))
    }
}
