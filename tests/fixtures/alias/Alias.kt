package alias

interface Pump {
    fun beat()
}

class Piston : Pump {
    override fun beat() {}
}

class Valve : Heart {
    override fun beat() {}
}

class Lung {
    fun beat() {}
}

typealias Heart = Pump

typealias OnBeat = (Int) -> Unit

class Body(val heart: Heart, val lung: Lung, val onBeat: OnBeat) {
    fun live() = heart.beat()
}
