package gd.recv.use

import gd.recv.Crate
import gd.recv.Hue
import gd.recv.Ledger
import gd.recv.Orb
import gd.recv.Speed
import gd.recv.bulk

fun use(crate: Crate) {
    val orb = Orb(2)
    val typed: Orb = orb
    println(crate.extent()) // param type
    println(orb.extent()) // ctor type
    println(typed.span) // declared type
    println(crate.ident) // inherited
    println(Crate.CAP) // companion val
    println(Crate.make()) // companion fun
    println(Hue.TEAL) // one-line enum
    println(Speed.SLOW) // enum entry line
    println(orb.bulk()) // orb extension
    println(crate.bulk()) // crate extension
    println(Crate(3).extent()) // ctor call receiver
    println(orb?.span) // safe call
    val ref = Orb::extent
    println(gd.recv.Hue.CRIMSON) // qualified
    Ledger.enroll(label = "x", span = 1)
    Ledger.enroll(
        label = "y",
    )
    println(Orb(span = 2)) // ctor named arg
    var total = 0
    total = 5
}
