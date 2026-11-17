// Where the probe's bottom bar item goes on the Mac, whose toolbars have no
// bottom bar (Placements.swift is the others'): the window's toolbar.

import SwiftUI

extension ToolbarItemPlacement {
    static var probeBottomBar: ToolbarItemPlacement { .automatic }
}
