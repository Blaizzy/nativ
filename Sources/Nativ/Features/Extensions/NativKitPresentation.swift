import SwiftUI

extension NativKit {
    var symbol: String {
        switch id {
        case "engineering": "hammer"
        case "research": "magnifyingglass"
        default: "shippingbox"
        }
    }

    var tint: Color {
        switch id {
        case "engineering": .blue
        case "research": .purple
        default: .indigo
        }
    }
}
