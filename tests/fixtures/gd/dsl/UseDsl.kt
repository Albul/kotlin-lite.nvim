package gd.dsl

fun useDsl() {
    canvas {
        stroke(1) // dsl canvas
    }
    pen(tint = "red") {
        listOf(1).forEach {
            stroke(it) // dsl pen through a plain lambda
        }
    }
    val p = Pen()
    p.apply {
        stroke(3) // apply on pen
    }
    with(Canvas()) {
        stroke(4) // with canvas
    }
    val lazyPen by lazy { Pen() }
    lazyPen.stroke(5) // lazy type
    draw(y = 1, tint = "x", alpha = 1f) // overload by named args
    blend(1) // one arg
    blend(1, 2) // two args, third defaulted
    blend(1) { } // trailing lambda
}
