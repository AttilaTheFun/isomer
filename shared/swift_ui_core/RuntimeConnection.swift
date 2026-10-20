// The runtime as IsomerSwiftUI's `RuntimeConnection`: what a host outside
// Isomer's SwiftUI drives it with (shared/isomer_swift_ui/IsomerRuntime.swift).

package import IsomerSwiftUI

extension Runtime: RuntimeConnection {
    package func bindTreeRenderer(send: @escaping ([UInt8]) -> Void) {
        Renderer.bind(ComponentSystemRenderer(send: send))
    }

    package func pointer(_ phase: PointerPhase, x: Double, y: Double) {
        pointerEvent(kind: phase.rawValue, x: x, y: y)
    }

    package func wheel(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        wheelEvent(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
    }

    package func keyPress(id: String, value: String) -> Bool {
        keyPressEvent(id: id, value: value)
    }

    package func setDisplayScale(_ scale: Double) {
        displayScale = CGFloat(scale)
    }

    package func scenePhaseChanged(to phase: HostScenePhase) {
        switch phase {
        case .background: setScenePhase(ScenePhase.background)
        case .inactive: setScenePhase(ScenePhase.inactive)
        case .active: setScenePhase(ScenePhase.active)
        }
    }

    package func openURL(_ url: String) {
        openURL(external: url)
    }
}
