package impl.user

import impl.shapes.Polygon

class Triangle : Polygon() {
    override val sides = 3
    override fun surface() = 0.5
}
