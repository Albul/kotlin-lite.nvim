package fixtures

const val TOP_CONST = 1
var topVar = 2

fun topLevel(x: Int): Int {
    val localOnly = x + 1
    return localOnly
}

private fun hiddenFun() {}

interface Shape {
    fun perimeter(): Double
}

data class Point(val x: Int, private val secret: Int, z: Int) : Shape {
    val visible: Int = x
    private val hiddenField = 0
    var mutable: String = ""

    fun distance(): Double {
        val tmp = 0.0
        return tmp
    }

    companion object {
        val ORIGIN = Point(0, 0, 0)
    }
}
