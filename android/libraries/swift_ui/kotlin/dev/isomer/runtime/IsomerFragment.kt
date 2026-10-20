package dev.isomer.runtime

// Incremental adoption (Level 3) for classic View/Fragment host apps: a
// Fragment hosting the Isomer surface — the Fragment analogue of
// `UIHostingController`. Uses the self-drawing SwiftGPURenderer via
// `IsomerView`, which is self-contained inside any view hierarchy;
// Compose host apps should use the `Isomer()` composable instead.

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment

class IsomerFragment : Fragment() {
    private var surface: IsomerView? = null

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = IsomerView(requireActivity()).also {
        surface = it
        IsomerRuntime.attach(requireActivity())
    }

    override fun onResume() {
        super.onResume()
        surface?.onResume()
        IsomerRuntime.setScenePhase("active")
    }

    override fun onPause() {
        super.onPause()
        IsomerRuntime.setScenePhase("inactive")
        surface?.onPause()
    }

    override fun onStop() {
        super.onStop()
        IsomerRuntime.setScenePhase("background")
    }

    override fun onDestroyView() {
        super.onDestroyView()
        surface = null
    }

    /** Route a system back press to the runtime (pop nav / dismiss sheet);
     * `onUnhandled` runs when there was nothing to pop. */
    fun handleBack(onUnhandled: () -> Unit) {
        surface?.handleBack(onUnhandled) ?: onUnhandled()
    }
}
