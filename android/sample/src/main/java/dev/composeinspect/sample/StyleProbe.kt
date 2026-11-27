package dev.composeinspect.sample

import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

private val TicketShape = GenericShape { size, _ ->
    val w = size.width
    val h = size.height
    val notch = h * 0.18f
    fillType = PathFillType.EvenOdd
    moveTo(0f, 0f)
    lineTo(w, 0f)
    lineTo(w, h / 2 - notch)
    cubicTo(w - notch, h / 2 - notch, w - notch, h / 2 + notch, w, h / 2 + notch)
    lineTo(w, h)
    lineTo(0f, h)
    close()
    addOval(Rect(h * 0.18f, h * 0.38f, h * 0.42f, h * 0.62f))
}

/** Real modifier chains for SDK style integration checks; no inspector-specific API. */
@Composable
fun StyleProbe() {
    Column(Modifier.fillMaxSize().background(Color.White).verticalScroll(rememberScrollState()).padding(20.dp)) {
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
        BasicText("style-graphics-layer", Modifier.graphicsLayer(alpha = 0.6f, rotationZ = 12f, translationX = 5f))
        Spacer(Modifier.height(16.dp))
        Box(Modifier.width(180.dp).height(52.dp).clip(TicketShape)
            .background(Color(0xFF245C60), TicketShape), contentAlignment = Alignment.Center) {
            BasicText("导览票", style = TextStyle(color = Color.White, fontWeight = FontWeight.Bold))
        }
        Spacer(Modifier.height(12.dp))
        FloorPlanCard()
    }
}

@Composable
private fun FloorPlanCard() {
    var selectedRoom by remember { mutableStateOf("资料室") }
    val ink = Color(0xFF173D3C)
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp))
            .background(Color(0xFFE7EEEA)).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(38.dp).background(ink, CutCornerShape(topEnd = 8.dp)),
                contentAlignment = Alignment.Center) {
                BasicText("2F", style = TextStyle(color = Color.White, fontWeight = FontWeight.Bold))
            }
            BasicText("楼层导览", style = TextStyle(color = ink, fontSize = 20.sp, fontWeight = FontWeight.Bold))
        }
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(ink).padding(6.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    PlanRoom("会议室", Color(0xFFA5D4CB), Modifier.weight(2f)) { selectedRoom = "会议室" }
                    PlanRoom("资料室", Color(0xFFFFD299), Modifier.weight(1f)) { selectedRoom = "资料室" }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    PlanRoom("接待处", Color(0xFFB6CBE4), Modifier.weight(1f)) { selectedRoom = "接待处" }
                    PlanRoom("工作区", Color(0xFFC9DAAB), Modifier.weight(2f)) { selectedRoom = "工作区" }
                }
            }
            // This marker straddles both room rows so the scene has genuine overlapping siblings.
            Box(Modifier.align(Alignment.Center).size(24.dp).clip(CircleShape)
                .background(Color.White).padding(4.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.fillMaxSize().background(Color(0xFFCE603C), CircleShape))
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            BasicText("已选房间", style = TextStyle(color = ink))
            BasicText(selectedRoom, style = TextStyle(color = ink, fontWeight = FontWeight.Bold))
        }
    }
}

@Composable
private fun PlanRoom(name: String, color: Color, modifier: Modifier, onSelect: () -> Unit) {
    Box(modifier.height(52.dp).clip(CutCornerShape(bottomEnd = 9.dp))
        .background(color).clickable(onClick = onSelect).padding(8.dp),
        contentAlignment = Alignment.CenterStart) {
        BasicText(name, style = TextStyle(color = Color(0xFF203536), fontSize = 14.sp))
    }
}
