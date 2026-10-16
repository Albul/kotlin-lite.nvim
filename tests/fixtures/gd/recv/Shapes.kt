package gd.recv

open class Vessel {
    val ident = 0
    open fun summary() = "vessel"
}

class Crate(val span: Int) : Vessel() {
    fun extent() = span * span

    fun scaled(): Int {
        val span = 2
        return span * this.span
    }

    override fun summary() = "crate " + super.summary()

    companion object {
        const val CAP = 10
        fun make() = Crate(1)
    }
}

class Orb(val span: Int) {
    fun extent() = 3 * span * span
}

enum class Hue { CRIMSON, TEAL }

enum class Speed {
    FAST,
    SLOW;
}

fun Crate.bulk() = span * span * span
fun Orb.bulk() = 4 * span

object Ledger {
    fun enroll(label: String, span: Int = 0) {}
}
