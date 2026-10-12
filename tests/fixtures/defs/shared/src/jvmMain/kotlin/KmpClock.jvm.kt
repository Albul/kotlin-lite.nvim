package defs

actual class KmpClock {
    actual fun now(): Long = System.currentTimeMillis()
}
