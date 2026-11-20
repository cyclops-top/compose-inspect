package dev.composeinspect.sample

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

/** Real modifier chains for SDK style integration checks; no inspector-specific API. */
@Composable
fun StyleProbe() {
    Column(Modifier.fillMaxSize().background(Color.White).padding(20.dp)) {
        BasicText("style-layered", Modifier
            .background(Color(0xFF112233), RoundedCornerShape(12.dp))
            .padding(start = 7.dp, top = 11.dp, end = 13.dp, bottom = 17.dp)
            .clip(CutCornerShape(4.dp))
            .background(Color(0x80445566))
            .padding(PaddingValues(horizontal = 3.dp, vertical = 5.dp)))
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Rtl) {
            BasicText("style-rtl", Modifier
                .background(Color.Green, RoundedCornerShape(topStart = 2.dp, topEnd = 6.dp,
                    bottomEnd = 10.dp, bottomStart = 14.dp))
                .padding(start = 3.dp, top = 4.dp, end = 9.dp, bottom = 5.dp))
            BasicText("style-absolute", Modifier
                .background(Color.Blue, AbsoluteRoundedCornerShape(topLeft = 2.dp, topRight = 6.dp,
                    bottomRight = 10.dp, bottomLeft = 14.dp))
                .absolutePadding(left = 3.dp, top = 4.dp, right = 9.dp, bottom = 5.dp))
        }
        Box(Modifier.size(60.dp).clip(CircleShape).background(Color.Red))
        Box(Modifier.size(60.dp).background(Color.Yellow,
            RoundedCornerShape(CornerSize(10.dp), CornerSize(20), CornerSize(8f), CornerSize(6.dp))))
        Box(Modifier.size(50.dp).background(Brush.horizontalGradient(listOf(Color.Red, Color.Blue))))
    }
}
