package impl.shapes

// header forms the gri prefilter must not drop
class Blob(val a: Int,
           val b: Int): Shape {
    override fun surface() = 0.0
    override val name = "blob"
}

class Multi(
    val a: Int,
) : Comparable<Multi>,
    Shape {
    override fun surface() = 1.0
    override val name = "multi"
    override fun compareTo(other: Multi) = 0
}

class Listed :
    Comparable<Listed>, Shape {
    override fun surface() = 2.0
    override val name = "listed"
    override fun compareTo(other: Listed) = 0
}
