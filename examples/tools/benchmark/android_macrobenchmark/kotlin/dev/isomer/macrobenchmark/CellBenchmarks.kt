package dev.isomer.macrobenchmark

// The platform-native Android perf harness for the benchmark cells
// (docs/benchmarks.md#android): Jetpack Macrobenchmark driving REAL cold
// launches and REAL injected taps/swipes against a release, `speed`-compiled,
// profileable cell APK. The cell under test is chosen at run time:
//
//   adb shell am instrument -w \
//     -e targetAppId dev.isomer.tapcounter.wasmviews \
//     -e class dev.isomer.macrobenchmark.CellBenchmarks \
//     dev.isomer.macrobenchmark/androidx.test.runner.AndroidJUnitRunner
//
// Metrics:
//  - startup: StartupTimingMetric (COLD). timeToInitialDisplayMs is the
//    framework's process-create -> first-frame stamp; cells additionally call
//    reportFullyDrawn() at their [content-frame] (the first draw containing
//    the real content), surfacing timeToFullDisplayMs.
//  - interaction: 10 cycles of (50 ms settle -> tap the counter button ->
//    50 ms settle -> swipe up). The cell stamps an async trace section
//    "iso-tap" from ACTION_UP receipt to the first pre-draw carrying the
//    updated count; TraceSectionMetric aggregates it. Injection latency and
//    render-server work are excluded by construction.
//
// Rigor: one un-measured warmup iteration precedes each measurement
// (measureRepeated's first iteration is preceded by a manual warmup launch /
// cycle), >=500 ms between launches, >=50 ms between taps.

import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.ExperimentalMacrobenchmarkApi
import androidx.benchmark.macro.ExperimentalMetricApi
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.TraceSectionMetric
import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CellBenchmarks {
    @get:Rule
    val benchmarkRule = MacrobenchmarkRule()

    private val targetAppId: String =
        InstrumentationRegistry.getArguments().getString("targetAppId")
            ?: error("pass -e targetAppId <package under test>")

    private val device: UiDevice =
        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

    /** The busy-JS variants (-e targetBusy true): launch with the fork apps'
     *  `busy` intent extra, which starts their synthetic JS-thread load. */
    private val targetBusy: Boolean =
        InstrumentationRegistry.getArguments().getString("targetBusy") == "true"

    private fun MacrobenchmarkScope.launchCell() {
        if (targetBusy) {
            val pm = InstrumentationRegistry.getInstrumentation().context.packageManager
            val intent = checkNotNull(pm.getLaunchIntentForPackage(targetAppId))
            intent.putExtra("busy", true)
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivityAndWait(intent)
        } else {
            startActivityAndWait()
        }
    }

    /** Cold startup, 10 measured iterations (macro kills the process between
     *  iterations; the 500 ms inter-launch gap is enforced in setupBlock). */
    @OptIn(ExperimentalMacrobenchmarkApi::class)
    @Test
    fun startup() {
        var first = true
        benchmarkRule.measureRepeated(
            packageName = targetAppId,
            metrics = listOf(StartupTimingMetric()),
            // Ignore = use the installed ART state; the driver pins it with
            // `cmd package compile -m speed -f` (Full() would REINSTALL the
            // target to reset state, which shell instrumentation on API 31
            // cannot do).
            compilationMode = CompilationMode.Ignore(),
            startupMode = StartupMode.COLD,
            iterations = 10,
            setupBlock = {
                if (first) {
                    // Warmup: one un-measured launch, thrown away.
                    launchCell()
                    device.pressHome()
                    killProcess()
                    first = false
                }
                Thread.sleep(500)
            },
        ) {
            launchCell()
        }
    }

    /** The interaction benchmark: per iteration, 10 cycles of
     *  (50 ms -> tap the button -> 50 ms -> swipe up). The measured value is
     *  the cell's own "iso-tap" async section: ACTION_UP receipt -> first
     *  pre-draw carrying the update. */
    @OptIn(ExperimentalMacrobenchmarkApi::class, ExperimentalMetricApi::class)
    @Test
    fun interaction() {
        var first = true
        benchmarkRule.measureRepeated(
            packageName = targetAppId,
            metrics = listOf(
                TraceSectionMetric("iso-tap", mode = TraceSectionMetric.Mode.Average),
            ),
            compilationMode = CompilationMode.Ignore(),
            // No startupMode: COLD would kill the process AFTER setupBlock,
            // measuring against a dead UI. Launch state is managed here.
            startupMode = null,
            iterations = 5,
            setupBlock = {
                launchCell()
                // Warmup: one un-measured tap cycle, thrown away (its trace
                // sections land before measurement starts).
                if (first) {
                    interactionCycle()
                    first = false
                }
                Thread.sleep(500)
            },
        ) {
            repeat(10) { interactionCycle() }
        }
    }

    private fun interactionCycle() {
        Thread.sleep(50)
        // Most cells expose the button label as a real TextView (matched by
        // text); some renderers (e.g. Lynx's AndroidText) surface it only as a
        // content-description, so fall back to that.
        val button = device.wait(Until.findObject(By.textStartsWith("Tap me")), 3000)
            ?: device.wait(Until.findObject(By.descStartsWith("Tap me")), 3000)
            ?: error("no 'Tap me' button in $targetAppId")
        button.click()
        Thread.sleep(50)
        // Swipe up: scroll a few rows' worth of content.
        val h = device.displayHeight
        device.swipe(device.displayWidth / 2, h * 2 / 3, device.displayWidth / 2, h / 3, 10)
        Thread.sleep(50)
    }
}
