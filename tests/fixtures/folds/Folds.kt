package folds

/**
 * A KDoc
 * of several lines.
 */
class Folds(
    val a: Int,
    val b: Int,
) {
    fun call() = listOf(
        a,
        b,
    )

    fun guarded(): Int {
        try {
            return a / b
        } catch (e: ArithmeticException) {
            return 0
        } finally {
            println("done")
        }
    }

    fun params(
        first: Int,
        second: Int,
    ): Int = first + second

    val text = """
        raw
    """

    /* a block
       comment */
    fun one(x: Int) = listOf(x)
}
