import SwiftUI

/// Uses the current scene width so folded screens and resizable iPad windows
/// follow the same browsing layout as other compact or expanded containers.
struct BrowseLayout {
    let availableWidth: CGFloat

    init(width: CGFloat) {
        availableWidth = max(0, width)
    }

    var isWide: Bool { availableWidth >= 600 }
    var horizontalInset: CGFloat { isWide ? 24 : 16 }
    var contentWidth: CGFloat { min(max(0, availableWidth - horizontalInset * 2), 1_200) }
    var columnSpacing: CGFloat { 14 }
    var columnCount: Int {
        max(2, min(6, Int((contentWidth + columnSpacing) / (180 + columnSpacing))))
    }
    var shelfCardWidth: CGFloat { isWide ? 170 : 142 }
    var resultColumnCount: Int { contentWidth >= 700 ? 2 : 1 }
}
