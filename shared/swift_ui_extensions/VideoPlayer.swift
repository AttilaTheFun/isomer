// A video player bridged to the platform's native player: a `<video>` element
// on the web and a `VideoView` on Android, made from the video's URL. Isomer's,
// not AVKit's (whose `VideoPlayer` takes an `AVPlayer`): on Apple platforms
// an app uses AVKit's.

import Foundation
import SwiftUI

public struct VideoPlayer {
    let urlString: String

    public init(url: URL?) {
        self.urlString = url?.absoluteString ?? ""
    }

    public var kind: String { "video" }
    public var value: String { urlString }
    public func onValueChanged(_ value: String) {}
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension VideoPlayer: PlatformViewRepresentable {}
