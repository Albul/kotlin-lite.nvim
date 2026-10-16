package gd.dsl

class Canvas {
    fun stroke(width: Int) {}
}

class Pen {
    fun stroke(width: Int, dash: Boolean = false) {}
}

fun canvas(block: Canvas.() -> Unit) {}

fun pen(
    tint: String = "black",
    block: Pen.() -> Unit,
) {}

fun draw(x: Int, tint: String) {}

fun draw(y: Int, tint: String, alpha: Float) {}

fun blend(a: Int) {}

fun blend(a: Int, b: Int, c: Int = 0) {}

fun blend(a: Int, block: () -> Unit) {}

interface Painter {
    val layer: Int
    fun paint(layer: Int)
}
