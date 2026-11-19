import Algorithms
import Foundation

/// The elements in runs of two (swift-algorithms' `chunks(ofCount:)`),
/// through a Foundation the dependency declares no edge to.
public func chunked(_ values: [Int]) -> [[Int]] {
    _ = Date()
    return values.chunks(ofCount: 2).map(Array.init)
}
