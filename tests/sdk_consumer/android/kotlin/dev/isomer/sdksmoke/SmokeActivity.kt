package dev.isomer.sdksmoke

import android.app.Activity
import android.os.Bundle
import android.util.Log

/** Runs the SDK's checks (smoke/Checks.swift) and logs each line under SDKSMOKE. */
class SmokeActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    for (line in SmokeBridge.smokeReport().lines()) {
      Log.i("SDKSMOKE", line)
    }
    finish()
  }
}
