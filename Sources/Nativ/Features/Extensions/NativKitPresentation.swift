import SwiftUI

extension NativKit {
    var symbol: String {
        switch id {
        case "engineering": "chevron.left.forwardslash.chevron.right"
        case "research": "magnifyingglass"
        default: "shippingbox"
        }
    }

    var tint: Color {
        switch id {
        case "engineering": .indigo
        case "research": .purple
        default: .teal
        }
    }
}
