package libsdemo

import kotlinx.coroutines.flow.Flow
import kotlin.test.Test
import kotlin.time.Duration.Companion.ZERO
import kotlin.time.Duration.Companion.days
import com.example.pathy.Pathy

fun libsFlow(): Flow<Int> = TODO()

class LibsTest {
    @Test fun libsCase() = Unit
}

fun libsZero() = ZERO

fun libsPathy(p: Pathy) = p.asText()

fun libsDaysInt() = 3.days
fun libsDaysLong() = 3L.days
fun libsDaysDouble() = 1.5.days
fun libsDaysOf(n: Int) = n.days

class Span { val days = 1 }
fun libsSpan(s: Span) = s.days
