package defs.user

import defs.other.Dup
import defs.main.Outer.Inner
import defs.main.dupFun as aliasFun
import defs.missing.Dup

fun use(d: Dup, i: Inner) = aliasFun()
