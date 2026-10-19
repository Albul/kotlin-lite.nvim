package usages.b

import usages.a.Account
import usages.a.open

fun bank(a: Account) {
    a.balance = 1
    val l = usages.a.Ledger()
    l.balance = 2
    open(name = "x").deposit(amount = 3)
    println("balance")
    open(name = "y").balance = 4
}
