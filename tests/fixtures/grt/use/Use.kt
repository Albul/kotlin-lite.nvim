package grt.use

import grt.model.Car
import grt.model.Person
import grt.model.Rocket
import grt.model.defaultCar
import grt.model.garage

class Driver(private val car: Car, private val rocket: Rocket) {
    val backup: Car? = null

    fun drive() {
        car.engine.start() // chain member
        val e = car.engine
        e.power // local typed by a chain
        car.spare().pump() // call result
        garage().engine // top-level fun result
        defaultCar.engine // top-level val
        backup?.spare() // nullable
        val n = 3
        val p = car.owner() // expression-bodied fun
        p.name // via owner()
        println(n)
        Person("y") // explicit import
    }
}
