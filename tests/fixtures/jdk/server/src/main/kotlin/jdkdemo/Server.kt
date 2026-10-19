package jdkdemo

import java.sql.Connection
import java.time.Instant

fun jdkNow(): Instant = Instant.now()
fun jdkWorker() = Thread()
fun jdkName(): String = "x"
fun jdkDb(c: Connection) = c.isClosed
fun jdkInternal() = Unsafe()
fun jdkLength() = "x".length
fun jdkFail(): Exception = Exception("x")
