package impl.painters

interface Painter {
    fun paint(layer: Int)
}

open class Brush : Painter {
    override fun paint(layer: Int) {}
}

class FineBrush : Brush() {
    override fun paint(layer: Int) {}
}

class Roller : Painter {
    override fun paint(layer: Int) {}
}

interface Wall {
    fun paint(layer: Int)
    fun crack()
}

class Brick : Wall {
    override fun paint(layer: Int) {}
    override fun crack() {}
}

fun use(p: Painter, w: Wall) {
    p.paint(1) // painter
    w.paint(2) // wall
    with(p) {
        paint(3) // with painter
    }
    val local = 1
    println(local) // local
}

fun unknown(walls: List<Wall>) {
    walls[0].paint(4) // unknown receiver
    walls[0].crack() // unknown receiver, one root
}

private fun hidden() {}
