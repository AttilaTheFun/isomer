package com.example.greeter

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

/** Exercises the generated swift_ffi bindings and shows the results. */
class MainActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    val lines = mutableListOf<String>()

    // A String copied across the boundary in both directions.
    lines += GreeterBridge.greeting("Android")

    // Scalars over the flat C ABI.
    lines += "add(19, 23) = ${GreeterBridge.add(19, 23)}"
    lines += "isEven(42) = ${GreeterBridge.isEven(42)}"

    // An interface crossing as an owned handle: `use` gives the confined
    // (deterministic) disposal mode; leaked wrappers are backstopped by the
    // finalizer.
    GreeterBridge.makeCounter("taps").use { counter ->
      counter.increment()
      counter.increment()
      counter.increment()
      lines += counter.label()
    }

    // Interface parameters going Kotlin -> Swift: a Swift-owned wrapper
    // passes its handle; a plain Kotlin implementation of Counter crosses as
    // a foreign object Swift calls back into.
    GreeterBridge.makeCounter("swift-side").use { counter ->
      counter.increment()
      lines += GreeterBridge.describe(counter)
    }
    val kotlinCounter = object : Counter {
      override fun increment() = 7L
      override fun label() = "a Kotlin counter"
    }
    lines += GreeterBridge.describe(kotlinCounter)

    // The reverse direction: a Kotlin object implements the Swift protocol
    // GreetingObserver and is passed *into* Swift, which calls back out
    // through the foreign proxy — with parameters crossing both ways,
    // including an interface parameter going Swift -> Kotlin (sessionEnded
    // receives an owned SwiftCounter).
    val observer = object : GreetingObserver {
      override fun greetingDelivered(greeting: String, index: Long) {
        lines += "observer #$index: $greeting"
      }

      override fun shouldContinue(after: Long) = after < 3

      override fun sessionEnded(tally: SwiftCounter) {
        tally.use {
          it.increment()
          lines += "session ended: ${it.label()}"
        }
      }
    }
    val delivered = GreeterBridge.deliverGreetings(observer, "Kotlin", 10)
    lines += "delivered $delivered greetings"

    // Structs are copied field-wise as data classes; bytes as ByteArray.
    val metrics = GreeterBridge.measure("hi", 10.0)
    lines += "measure(\"hi\") = ${metrics.label} ${metrics.width}x${metrics.height}"
    lines += "area(3x4) = ${GreeterBridge.area(TextMetrics(3.0, 4.0, "x"))}"
    lines += GreeterBridge.describeMetrics(object : MetricsProvider {
      override fun metrics(scale: Double) = TextMetrics(scale * 3, 4.0, "from Kotlin")
    })
    lines += "checksum(1,2,3) = ${GreeterBridge.checksum(byteArrayOf(1, 2, 3))}"

    // Swift `throws` and `Result` returns both bridge as kotlin.Result.
    lines += GreeterBridge.requireEven(42).fold(
      { "requireEven(42) = $it" },
      { "requireEven(42) failed: ${it.message}" })
    lines += GreeterBridge.parseNumber("nope").fold(
      { "parseNumber(\"nope\") = $it" },
      { "parseNumber(\"nope\") failed: ${it.message}" })

    val view = TextView(this)
    view.textSize = 20f
    view.setPadding(48, 96, 48, 48)
    view.text = lines.joinToString("\n\n")
    val scroller = ScrollView(this)
    scroller.addView(view)
    setContentView(scroller)

    // Async Swift functions bridge as suspend functions; the stdlib
    // startCoroutine keeps the example free of kotlinx-coroutines (a real app
    // would use lifecycleScope.launch). The completion resumes on Swift's
    // executor thread, so hop back to the main thread to touch the view.
    val fetchLines = suspend {
      listOf(
        "motd: ${GreeterBridge.fetchMotd()}",
        GreeterBridge.fetchNumber(41).fold(
          { "fetchNumber(41) = $it" },
          { "fetchNumber(41) failed: ${it.message}" }),
        GreeterBridge.fetchNumber(1000).fold(
          { "fetchNumber(1000) = $it" },
          { "fetchNumber(1000) failed: ${it.message}" }),
      )
    }
    fetchLines.startCoroutine(
      Continuation(EmptyCoroutineContext) { result ->
        view.post {
          lines += result.getOrThrow()
          view.text = lines.joinToString("\n\n")
        }
      })
  }
}
