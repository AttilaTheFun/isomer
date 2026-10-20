import Foundation
import SwiftFFIIRLibrary


extension FFIParameter {
    /// The Swift-side value name for a parameter inside generated proxies.
    func name(_ index: Int) -> String {
        label == "_" ? "arg\(index)" : label
    }
}
