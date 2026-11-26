package dev.isomer.runtime

// A shake, from the accelerometer, for the Isomer module's `.onShake`: the
// sensor is on only while a view has one (the runtime's "shake" command),
// and while the activity is resumed, so a phone in a pocket with the app in
// the background reads nothing. A shake is several quick jolts well past
// gravity's pull within half a second, then a second's rest before the next.

import android.app.Activity
import android.app.Application
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import android.os.SystemClock

internal object ShakeDetector : SensorEventListener {
    /** Acceleration (m/s²) a jolt passes: about 2.7 g, past a wave or a walk. */
    private const val JOLT = 2.7f * SensorManager.GRAVITY_EARTH
    private const val JOLTS = 3
    private const val WINDOW_MS = 500L
    private const val REST_MS = 1000L

    private var wanted = false
    private var activity: Activity? = null
    private var onShake: (() -> Unit)? = null
    private var registered = false
    private var lifecycle: Application.ActivityLifecycleCallbacks? = null
    private val jolts = ArrayDeque<Long>()
    private var lastShake = 0L

    /** Listens for shakes on [activity] (calling [shaken] on the main thread
     *  for each) when [on], or stops. */
    fun listen(activity: Activity, on: Boolean, shaken: () -> Unit) {
        wanted = on
        onShake = shaken
        if (this.activity !== activity) {
            stop()
            this.activity = activity
            watchLifecycle(activity)
        }
        if (on) start() else stop()
    }

    private fun start() {
        val activity = activity ?: return
        if (registered || !wanted) return
        val sensors = activity.getSystemService(SensorManager::class.java) ?: return
        val accelerometer = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return
        registered = sensors.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME)
    }

    private fun stop() {
        if (!registered) return
        activity?.getSystemService(SensorManager::class.java)?.unregisterListener(this)
        registered = false
        jolts.clear()
    }

    /** Off while the activity is paused, on again when it resumes (if a view
     *  still wants it). */
    private fun watchLifecycle(activity: Activity) {
        lifecycle?.let { activity.application.unregisterActivityLifecycleCallbacks(it) }
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) { if (a === this@ShakeDetector.activity) start() }
            override fun onActivityPaused(a: Activity) { if (a === this@ShakeDetector.activity) stop() }
            override fun onActivityDestroyed(a: Activity) {
                if (a !== this@ShakeDetector.activity) return
                stop()
                a.application.unregisterActivityLifecycleCallbacks(this)
                this@ShakeDetector.activity = null
                lifecycle = null
            }
            override fun onActivityCreated(a: Activity, state: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, state: Bundle) {}
        }
        lifecycle = callbacks
        activity.application.registerActivityLifecycleCallbacks(callbacks)
    }

    override fun onSensorChanged(event: SensorEvent) {
        val (x, y, z) = Triple(event.values[0], event.values[1], event.values[2])
        if (x * x + y * y + z * z < JOLT * JOLT) return
        val now = SystemClock.uptimeMillis()
        if (now - lastShake < REST_MS) return
        jolts.addLast(now)
        while (jolts.isNotEmpty() && now - jolts.first() > WINDOW_MS) jolts.removeFirst()
        if (jolts.size < JOLTS) return
        jolts.clear()
        lastShake = now
        onShake?.invoke()
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
}
