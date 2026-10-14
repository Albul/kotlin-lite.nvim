package impl.other

// same simple name as impl.shapes.Shape -- must not mix with it
interface Shape {
    fun surface(): Double
}

class Fake : Shape {
    override fun surface() = 1.0
}
