package autoimport.use

import autoimport.base.AiBase

class AiChild : AiBase() {
    fun f() {
        aiShared() // inherited member
    }
}

fun outside() {
    aiShared() // not a member here
}
