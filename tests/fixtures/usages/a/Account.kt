package usages.a

class Account(val owner: String) {
    var balance = 0
    private val secret = 1

    fun deposit(amount: Int) {
        balance += amount
        val balance = 5 // shadows the member
        println(balance)
        println(secret)
    }

    // balance in a comment
    fun total(): Int = balance + secret
}

class Ledger {
    var balance = 100
    fun audit() = balance
}

fun open(name: String): Account = Account(owner = name)
