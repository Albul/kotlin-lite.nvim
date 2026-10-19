package fetchfix

import com.example.remote.core.RemoteWidget
import com.example.remote.core.remoteHelper
import com.example.remote.core.MAX_WIDGETS
import java.time.Instant
import fetchfix.local.Missing

class Uses : RemoteWidget() {
    val at: Instant = Instant.now()
    val gone: Missing? = null
}
