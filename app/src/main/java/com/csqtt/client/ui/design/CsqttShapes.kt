package com.wstt.client.ui.design

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.runtime.Immutable
import androidx.compose.ui.unit.dp

@Immutable
object WsttShapes {
    val Small = RoundedCornerShape(22.dp)
    val Control = RoundedCornerShape(percent = 50)
    val Card = RoundedCornerShape(34.dp)
    val LargeCard = RoundedCornerShape(42.dp)
    val Dialog = RoundedCornerShape(40.dp)
    val Pill = RoundedCornerShape(percent = 50)
}

val WsttMaterialShapes = Shapes(
    extraSmall = WsttShapes.Small,
    small = WsttShapes.Small,
    medium = WsttShapes.Control,
    large = WsttShapes.Card,
    extraLarge = WsttShapes.Dialog,
)
