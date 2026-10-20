package dev.swiftmap.example

import android.app.Activity
import android.os.Bundle
import dev.swiftmap.runtime.MapView

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Launch extras override the initial camera, e.g.
        //   adb shell am start ... --ed bearing 30.0 --ed tilt 50.0
        fun extra(name: String, fallback: Double) =
            intent?.getDoubleExtra(name, fallback) ?: fallback
        val map = MapView(
            this,
            latitude = extra("latitude", 37.7749),
            longitude = extra("longitude", -122.4194),
            zoom = extra("zoom", 12.0),
            bearing = extra("bearing", 0.0),
            tilt = extra("tilt", 0.0),
        )
        // Sample overlays: SF landmarks + the Golden Gate Park footprint.
        map.setAnnotations(
            "ferry|37.7955|-122.3937|1|0.23|0.19|1|8|Ferry Building;" +
                "goldengate|37.8199|-122.4783|0|0.48|1|1|8|Golden Gate Bridge;" +
                "alcatraz|37.8270|-122.4230|0.2|0.78|0.35|1|10|Alcatraz Island",
        )
        map.setPolylines(
            "ferryroute|0,0.48,1,0.9|4|" +
                "37.7955,-122.3937;37.8080,-122.4090;37.8210,-122.4180;37.8270,-122.4230",
        )
        map.setPolygons(
            "goldengatepark|0.2,0.78,0.35,0.35|0.2,0.78,0.35,1,3|" +
                "37.7714,-122.5110;37.7748,-122.4553;37.7680,-122.4547;37.7645,-122.5104",
        )
        setContentView(map)
    }
}
