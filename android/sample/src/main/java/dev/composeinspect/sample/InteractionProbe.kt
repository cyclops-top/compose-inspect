package dev.composeinspect.sample

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

@Composable
fun InteractionProbe() {
    Column(Modifier.padding(20.dp)) {
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
            BasicText("click-enabled", Modifier.clickable { }.padding(12.dp))
            BasicText("click-disabled", Modifier.clickable(enabled = false) { }.padding(12.dp))
            BasicText("click-plain", Modifier.padding(12.dp))
            BasicText("click-long-only", Modifier.semantics { onLongClick { true } }.padding(12.dp))
            BasicText("click-custom", Modifier.semantics { onClick("Open") { true } }.padding(12.dp))
        }
    }
}
