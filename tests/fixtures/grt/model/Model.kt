package grt.model

class Engine {
    val power: Int = 1
    fun start(): Boolean = true
}

class Car(val engine: Engine) {
    val wheels = listOf(Wheel())
    fun spare(): Wheel = Wheel()
    fun owner() = Person("x")
}

class Wheel {
    val size = 16
    fun pump() {}
}

data class Person(val name: String)

class Rocket {
    val engine = Engine()
    val power = 9
    val name = "r"
    fun start(): Boolean = false
    fun spare(): Wheel = Wheel()
    fun pump() {}
}

fun garage(): Car = Car(Engine())
val defaultCar = Car(Engine())
