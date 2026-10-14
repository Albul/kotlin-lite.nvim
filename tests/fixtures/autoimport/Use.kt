package autoimport.use

fun use() {
    val c = Circle(1.0)
    val b = ByteArray(16)
    aiTopFun(1)
    "a".aiShout()
    println(aiTopVal + AI_TOP_CONST)
    println(AI_MAX + aiHelper() + AI_ONE)
    val n = AiNested()
    println(AI_COMP)
    println(AI_RED + AI_LARGE)
    println(AI_LIMIT + aiTwice(2))
    val i = AiInner()
    AiOuter(1).aiMember()
    aiHidden()
    println(aiLocal + aiCtorProp + aiInstance)
    aiDup()
}
