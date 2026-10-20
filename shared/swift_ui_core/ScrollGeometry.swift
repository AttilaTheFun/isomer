// `onScrollGeometryChange`: a scroll view's geometry (where it is scrolled
// to, how large its content is, the room it shows it in) as its host reports
// it, run through the app's transform; the action runs when the transformed
// value changes, as SwiftUI's does.

import Foundation

/// A scroll view's geometry, in points.
public struct ScrollGeometry: Equatable, Sendable {
    public var contentOffset: CGPoint
    public var contentSize: CGSize
    public var contentInsets: EdgeInsets
    public var containerSize: CGSize

    public init(contentOffset: CGPoint, contentSize: CGSize, contentInsets: EdgeInsets, containerSize: CGSize) {
        self.contentOffset = contentOffset
        self.contentSize = contentSize
        self.contentInsets = contentInsets
        self.containerSize = containerSize
    }

    /// The part of the content shown.
    public var visibleRect: CGRect { CGRect(origin: contentOffset, size: containerSize) }
    public var bounds: CGRect { visibleRect }

    /// A host's report: "offsetX,offsetY,contentW,contentH,containerW,
    /// containerH,insetTop,insetLeading,insetBottom,insetTrailing".
    init?(hostValue: String) {
        let parts = hostValue.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 10 else { return nil }
        contentOffset = CGPoint(x: parts[0], y: parts[1])
        contentSize = CGSize(width: parts[2], height: parts[3])
        containerSize = CGSize(width: parts[4], height: parts[5])
        contentInsets = EdgeInsets(top: parts[6], leading: parts[7], bottom: parts[8], trailing: parts[9])
    }
}

extension View {
    /// Runs `action` with the old and new value of `transform` over the
    /// scroll view's geometry whenever that value changes.
    nonisolated public func onScrollGeometryChange<T: Equatable>(
        for type: T.Type,
        of transform: @escaping (ScrollGeometry) -> T,
        action: @escaping (_ oldValue: T, _ newValue: T) -> Void
    ) -> some View {
        _ModifiedView(child: self, descend: "scrollgeometry", pure: true) { inner, ctx in
            let key = ctx.path + "/scrollgeometry"
            var current: RenderNode? = inner
            while let n = current {
                if case .scroll = n.kind {
                    n.scrollGeometryHandlers.removeAll { $0.key == key }
                    n.scrollGeometryHandlers.append((key, { geometry in
                        let new = transform(geometry)
                        let runtime = Runtime.shared
                        if let old = runtime.scrollGeometryValues[key] as? T {
                            guard old != new else { return }
                            runtime.scrollGeometryValues[key] = new
                            action(old, new)
                        } else {
                            runtime.scrollGeometryValues[key] = new
                        }
                    }))
                    break
                }
                if case .box = n.kind, n.children.count == 1 { current = n.children.first } else { break }
            }
            return inner
        }
    }

}
