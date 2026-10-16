package fixtures

/* a { brace in a block comment */
class Tricky {
    val raw = """
        { not a block
        fun fake() {}
    """
    val esc = "quote \" { "
    fun inside() {}
}

fun after() {}
