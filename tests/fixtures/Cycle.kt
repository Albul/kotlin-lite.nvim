package fixtures

const val PHASE_MILLIS_FACTOR = 100L
const val PHASE_CONST_TIME_FACTOR = -1L
const val INT_UNIT_MAX = 99
const val FRACTIONAL_UNIT_DIVISOR = 1000
const val MILLIS_PER_SECOND = 1000

enum class CyclePhase { REPOSE, INHALE, RETAIN, EXHALE, SUSTAIN }

object CycleType {
    const val BREATHING = 0
    const val REPOSE = 1
}
data class CycleEntry(
    val type: Int,
    val inhaleUnit: Int,
    val retainUnit: Int,
    val exhaleUnit: Int,
    val sustainUnit: Int,
    val reposeUnit: Int,
    val millisPerUnit: Long,
) {

    init {
        require(
            (isReposeCycle && reposeUnit != 0) ||
                (isBreathingCycle && (inhaleUnit != 0 || retainUnit != 0 || exhaleUnit != 0 || sustainUnit != 0))
        ) { "At least one unit must be non-zero" }
    }

    constructor(
        inhaleUnit: Int = 0,
        retainUnit: Int = 0,
        exhaleUnit: Int = 0,
        sustainUnit: Int = 0,
        millisPerUnit: Long,
    ) : this(CycleType.BREATHING, inhaleUnit, retainUnit, exhaleUnit, sustainUnit, reposeUnit = 0, millisPerUnit)

    constructor(
        reposeUnit: Int = 0,
        millisPerUnit: Long,
    ) : this(CycleType.REPOSE, inhaleUnit = 0, retainUnit = 0, exhaleUnit = 0, sustainUnit = 0, reposeUnit, millisPerUnit)

    val isReposeCycle: Boolean
        get() = type == CycleType.REPOSE

    val isBreathingCycle: Boolean
        get() = type == CycleType.BREATHING

    val cycleSeconds: Int
        get() = (cycleMillis / MILLIS_PER_SECOND).toInt()

    val cycleMillis: Long
        get() = if (isReposeCycle) {
            reposeMillis
        } else {
            inhaleMillis + retainMillis + exhaleMillis + sustainMillis
        }

    private fun convertToActualUnits(unit: Int): Float = when {
        unit < 0 -> 0f
        unit > INT_UNIT_MAX -> unit / FRACTIONAL_UNIT_DIVISOR.toFloat()
        else -> unit.toFloat()
    }

    fun isConstantCycle(): Boolean =
        if (isReposeCycle) {
            reposeUnit <= 0
        } else {
            inhaleUnit <= 0 && retainUnit <= 0 && exhaleUnit <= 0 && sustainUnit <= 0
        }

    fun isConstantPhase(phase: CyclePhase): Boolean = getPhaseUnit(phase) < 0

    fun getPhaseMillis(phase: CyclePhase): Long =
        unitToMillis(getPhaseUnit(phase))

    private fun unitToMillis(unit: Int): Long = when {
        unit < 0            -> unit * PHASE_CONST_TIME_FACTOR
        unit > INT_UNIT_MAX -> maxOf(unit.toLong() * millisPerUnit / FRACTIONAL_UNIT_DIVISOR, PHASE_MILLIS_FACTOR)
        else                -> unit * millisPerUnit
    }

    companion object {
        fun asConstantPhase(millis: Long) {
            return (millis * PHASE_CONST_TIME_FACTOR).toInt()
        }
    }
}
