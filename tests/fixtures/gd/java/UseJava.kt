package gd.java

fun useJava() {
    val legacy = Legacy.of("a")
    println(legacy.label())
    println(Legacy.LIMIT)
    println(Legacy.Kind.LARGE)
}
