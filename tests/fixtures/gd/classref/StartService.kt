package gd.classref

import android.content.Context
import android.content.Intent
import gd.classref.service.PracticeForegroundService

class StartService : Context() {
    fun start() {
        val intent = Intent(this, PracticeForegroundService::class.java)
        startService(intent)
    }
}
