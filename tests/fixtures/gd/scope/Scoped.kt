package gd.scope

class Scoped(val title: String) {
    val count = 1

    fun first() {
        val local = 1
        println(local)
    }

    fun second(): Int {
        println(title)
        return count
    }

    fun third(local: Int) {
        println(local * 2)
    }

    fun shadow() {
        val count = 2
        run {
            val count = 3
            println(count) // inner
        }
        println(count) // outer
    }

    fun order() {
        println(count) // before local
        val count = 4
        println(count) // after local
    }

    fun commented() {
        /*
        val count = 7
        */
        val text = "val count = 8"
        println(count) // masked
    }

    fun lambdas() {
        listOf(1).forEach { item ->
            println(item)
        }
        for (idx in 0..2) println(idx)
    }

    fun template() = "count is ${count}" // template

    fun later() = after

    val after = 5
}
