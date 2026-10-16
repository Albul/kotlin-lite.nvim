package calls

fun tally(n: Int): Int = n + 1

class Counter {
    val start = tally(0)

    init {
        tally(1)
    }

    fun bump() {
        listOf(1).forEach {
            tally(it)
        }
    }

    fun twice() =
        tally(tally(2))

    companion object {
        val zero = tally(-1)
    }
}

fun main() {
    tally(4)
}
