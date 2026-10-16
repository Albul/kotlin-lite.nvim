package calls.other

import calls.tally

object Ticker {
    fun tick(): Int {
        return tally(5)
    }
}

class TickerTest {
    val seed = 1

    fun `counts from seed`() {
        check(tally(seed) == 2)
    }
}
