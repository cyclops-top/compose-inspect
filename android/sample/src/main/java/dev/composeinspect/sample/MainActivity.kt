package dev.composeinspect.sample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.Popup

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val scenario = intent.getStringExtra("scenario") ?: "main"
        setContent {
            when (scenario) {
                "performance" -> PerformanceProbe()
                "styles" -> StyleProbe()
                "interactions" -> InteractionProbe()
                else -> ProbeScreen(scenario)
            }
        }
    }
}

data class Profile(val name: String, val age: Int, val tags: List<String>)

@Composable
private inline fun <reified T> probeValue(): T {
    BasicText("value-call-child")
    return remember(T::class) { "ComposeInspect capability probe" as T }
}

@Composable
private fun ProbeBoundary(body: @Composable () -> Unit) { body() }

@Composable
fun ProbeScreen(scenario: String) {
    var count by remember { mutableIntStateOf(7) }
    Column(Modifier.fillMaxSize().background(Color.White).padding(24.dp)) {
        val title = probeValue<String>()
        ProbeBoundary { BasicText(title) }
        ParameterCard("explicit-title", count, true, Profile("Ada", 37, listOf("compose", "debug")), 12.dp, Color.Red) { count++ }
        DefaultCard()
        InlineWrapper("inline-marker") { BasicText("inline-child") }
        NonRestartableCard("nonrestartable-marker", 42)
        NoLayoutWrapper("no-layout-marker") { BasicText("no-layout-child") }
        BasicText("Increment: $count", Modifier.clickable { count++ }.padding(12.dp))
        Canvas(Modifier.size(24.dp)) { drawCircle(Color.Blue) }
        LazyColumn(Modifier.height(180.dp)) {
            items((0 until 100).toList(), key = { it }) { index -> LazyRowProbe(index, "row-$index") }
        }
        if (scenario == "dialog") Dialog(onDismissRequest = {}) { DialogContent("dialog-marker") }
        if (scenario == "popup") Popup { PopupContent("popup-marker") }
    }
}

@Composable
fun ParameterCard(title: String, count: Int, enabled: Boolean, profile: Profile, spacing: Dp, tint: Color, onClick: () -> Unit) {
    Row(Modifier.background(tint).padding(spacing).clickable(enabled = enabled, onClick = onClick)) {
        BasicText("$title / $count / ${profile.name}")
    }
}

@Composable
fun DefaultCard(title: String = "default-title", count: Int = 23, nullable: String? = null) {
    BasicText("$title / $count / $nullable")
}

@Composable
inline fun InlineWrapper(label: String, content: @Composable () -> Unit) {
    Column { BasicText(label); content() }
}

@Composable
@NonRestartableComposable
fun NonRestartableCard(label: String, number: Int) { BasicText("$label / $number") }

@Composable
fun NoLayoutWrapper(label: String, content: @Composable () -> Unit) { BasicText(label); content() }

@Composable
fun LazyRowProbe(index: Int, label: String) { BasicText("$index: $label", Modifier.height(40.dp)) }

@Composable
fun DialogContent(label: String) { BasicText(label, Modifier.background(Color.White).padding(24.dp)) }

@Composable
fun PopupContent(label: String) { BasicText(label, Modifier.background(Color.Yellow).padding(24.dp)) }

// Fixed, eager composition makes repeated captures comparable (no lazy prefetch or animation).
@Composable
fun PerformanceProbe() {
    Column(Modifier.fillMaxSize().background(Color.White).padding(12.dp)) {
        BasicText("Capture baseline: 24 cards / 6 nested levels")
        repeat(12) { row ->
            Row(Modifier.fillMaxWidth().weight(1f)) {
                repeat(2) { column ->
                    Box(Modifier.weight(1f).fillMaxHeight().padding(2.dp)) {
                        PerformanceLayer(row * 2 + column, 6)
                    }
                }
            }
        }
    }
}

@Composable
fun PerformanceLayer(index: Int, depth: Int) {
    Box(Modifier.fillMaxSize().background(if (depth % 2 == 0) Color(0xFFE3F2FD) else Color(0xFFF1F8E9)).padding(1.dp)) {
        if (depth > 0) PerformanceLayer(index, depth - 1)
        else Column {
            BasicText("Card $index")
            BasicText("Stable capture", Modifier.clickable { })
        }
    }
}
