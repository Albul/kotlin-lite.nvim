package fixtures

import kotlin.math.PI

/**
 * A circle defined by its [radius].
 */
class Circle(val radius: Double) {

    /** Surface of the circle. */
    fun area(): Double {
        return PI * radius * radius
    }
}

/** Rectangle surface for the given sides. */
fun area(width: Double, height: Double): Double {
    return width * height
}
