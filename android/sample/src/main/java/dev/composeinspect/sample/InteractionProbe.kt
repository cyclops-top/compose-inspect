package dev.composeinspect.sample

import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.layout.height
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
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
            Column(Modifier.semantics(mergeDescendants = true) { }) {
                BasicText("mixed", Modifier.semantics {
                    selected = false
                    toggleableState = ToggleableState.Indeterminate
                })
            }
            LazyRow { items(30) { BasicText("row-$it", Modifier.padding(8.dp)) } }
            LazyVerticalGrid(GridCells.Fixed(2), Modifier.height(84.dp)) {
                items(20) { BasicText("grid-$it", Modifier.padding(8.dp)) }
            }
            BasicText("click-custom", Modifier.semantics { onClick("Open") { true } }.padding(12.dp))
        }
    }
}
