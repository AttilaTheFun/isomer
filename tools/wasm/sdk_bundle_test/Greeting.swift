// A library of the bundle's own (its deps'), which uses the Swift SDK's
// Foundation itself: a program built against the bundle finds the two
// together.

import Foundation

public func greeting(_ name: String) -> String {
    String(format: "Hello, %@: %d", name, 42)
}
