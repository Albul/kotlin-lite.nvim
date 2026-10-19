package libsdemo

import kotlinx.coroutines.flow.Flow
import kotlin.test.Test
import kotlin.time.Duration.Companion.ZERO
import com.example.pathy.Pathy

fun libsFlow(): Flow<Int> = TODO()

class LibsTest {
    @Test fun libsCase() = Unit
}

fun libsZero() = ZERO

fun libsPathy(p: Pathy) = p.asText()
