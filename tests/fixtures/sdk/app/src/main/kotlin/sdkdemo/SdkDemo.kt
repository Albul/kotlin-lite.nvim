package sdkdemo

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.NewIn37

class SdkDemo : Activity() {
    fun version() = Build.VERSION.SDK_INT
    fun code() = Build.VERSION_CODES.Q
    fun major() = Build.getMajorSdkVersion(1)
    fun color() = Color.TRANSPARENT
    fun fresh(): NewIn37? = null
    fun current() = intent
    fun pkg() = packageName
    fun action(i: Intent) = i.action
    fun worker() = Thread()
    fun logger() = Log.d("tag", "msg")
    fun win() = window
    fun contrast() = unknownWindow().isNavigationBarContrastEnforced
}
