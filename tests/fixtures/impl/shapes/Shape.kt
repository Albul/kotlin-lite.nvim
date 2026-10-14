package impl.shapes

interface Shape {
    fun surface(): Double
    val name: String
}

abstract class Polygon : Shape {
    abstract val sides: Int
    override val name: String get() = "polygon"
}

class Square(val side: Double) : Polygon() {
    override val sides = 4
    override fun surface() = side * side
}

class Disk(
    val r: Double,
    override val name: String,
) : Shape, Comparable<Disk> {
    override fun surface() = 3.14 * r * r
    override fun compareTo(other: Disk) = 0
}

val anon = object : Shape {
    override fun surface() = 0.0
    override val name = "anon"
}
