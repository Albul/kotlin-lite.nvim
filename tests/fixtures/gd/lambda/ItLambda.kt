package lambda

class Phase(val millis: Long)

class Plan(val phases: List<Phase>, val name: String?) {
    fun total() = phases.sumOf { it.millis }

    fun label() = name?.let { it.length } ?: 0

    fun named() = phases.map { p -> p.millis }

    fun outer() = phases.forEach {
        listOf(1).map { n -> n + it.millis }
        apply { println(it.millis) }
    }
}
