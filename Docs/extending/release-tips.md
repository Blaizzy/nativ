# Release tips

Release tips introduce a newly shipped capability beside the control that provides it. They are optional, easy to dismiss, and shown at most once by default. Nativ presents no more than one eligible release tip per day.

## Add a release tip

Define the tip beside the feature that owns it. Use a stable, versioned identifier so refactoring the Swift type does not show the same announcement again.

```swift
import SwiftUI
import TipKit

struct ToolDiscoveryReleaseTip: NativReleaseTip {
    static let stableID = "nativ.release.tool-discovery.v1"

    var title: Text {
        Text("Keep tools discoverable")
    }

    var message: Text? {
        Text("Discoverable tools stay out of context until Tool Search finds them.")
    }

    var image: Image? {
        Image(systemName: "sparkle.magnifyingglass")
    }
}
```

Attach it directly to the control it explains:

```swift
toolAccessControl
    .popoverTip(ToolDiscoveryReleaseTip(), arrowEdge: .top)
```

Invalidate the tip when someone uses the feature, even if the popover was never shown:

```swift
ToolDiscoveryReleaseTip().invalidate(reason: .actionPerformed)
```

Only change the identifier when the tip communicates a materially new capability. Increment the trailing revision, such as `v1` to `v2`, instead of encoding a Swift type or file name.

## Keep release tips useful

- Anchor the popover to the feature it describes.
- Use a short title and one sentence of supporting text.
- Never require the tip to operate the feature.
- Do not use release tips for errors, warnings, permission consent, or required onboarding.
- Prefer one tip for a small release. Use `TipGroup` only when related controls must be introduced in sequence.
- Keep content, eligibility rules, events, actions, and invalidation with the owning feature.

## Test locally

Debug builds support two launch arguments:

- `--reset-release-tips` clears TipKit state.
- `--show-all-release-tips` forces release tips to become eligible.

Use these only for development. Shipping builds retain TipKit state across launches so dismissed or completed tips stay dismissed.
