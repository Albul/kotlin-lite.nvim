package organize

import kotlin.math.max
import java.io.File
import a.b.used as renamed
import a.b.notUsed as alias
import kotlinx.coroutines.flow.Flow
import a.b.*
import a.b.Outer.Inner
import a.b.Unused
import a.b.getValue
import a.b.plus
import a.b.component1
import a.b.Documented
import a.b.InString
import a.b.InTemplate
import a.b.InComment
import kotlinx.coroutines.flow.Flow
import a.b.second

/**
 * See [Documented].
 */
class Holder(val flow: Flow<Inner>) {
    val lazyValue by lazy { renamed() + max(1, 2) }
    val text = "InString"
    val template = "$InTemplate"
    // InComment
    val s = listOf(1, 2).second()
}
