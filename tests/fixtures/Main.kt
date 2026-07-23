package fixtures

fun main() {
    val radius = 2.0
    val circle = Circle(radius)
    println(circle.area())

    val rectArea = area(3.0, 4.0)
    println(rectArea)

    describe(circle)
}

fun describe(circle: Circle) {
    println("circle with radius ${circle.radius}")
}
