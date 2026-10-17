package breadcrumbs

fun <T> List<T>.second(): T = this[1]

class Strategy<T : Any> {
    fun Scope<T>.calculate(entries: List<T>): T? {
        return entries.lastOrNull()
    }
}

private class Scene<T : Any>(
    override val key: Any,
    private val entry: T,
) : Overlay<T> {
    val content = entry
}
