package autoimport.lib

fun aiTopFun(x: Int) = x

fun String.aiShout(): String = uppercase()

val aiTopVal = 1

const val AI_TOP_CONST = 2

private fun aiHidden() = 0

fun aiDup() = 0

object AiConsts {
    const val AI_MAX = 10

    fun aiHelper() = 0
}

object AiOneLine { const val AI_ONE = 1 }

class AiOuter(val aiCtorProp: Int) {
    class AiNested

    fun aiMember() = 0

    companion object {
        const val AI_COMP = 1
    }

    fun aiLocalHost() {
        val aiLocal = 1
    }
}

enum class AiColor(val code: String) {
    AI_RED("r"),
    AI_GREEN("g");
}

enum class AiSize { AI_SMALL, AI_LARGE }
