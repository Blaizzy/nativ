import AppKit

/// A menu row whose embedded control performs an action without ending the
/// enclosing menu's tracking session.
@MainActor
final class PersistentMenuActionView: NSView {
    let optionID: String

    var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else { return }
            updateSelection()
        }
    }

    var isActionEnabled: Bool {
        get { actionButton.isEnabled }
        set {
            actionButton.isEnabled = newValue
            alphaValue = newValue ? 1 : 0.5
            updateAppearance()
        }
    }

    private let normalTitle: NSAttributedString
    private let titleLabel = NSTextField(labelWithString: "")
    private let selectionImage = NSImageView()
    private let optionImage = NSImageView()
    private let actionButton = NSButton()
    private let onSelect: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateAppearance()
        }
    }

    init(
        optionID: String,
        title: NSAttributedString,
        image: NSImage?,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) {
        self.optionID = optionID
        self.normalTitle = title
        self.isSelected = isSelected
        self.onSelect = onSelect

        let titleWidth = title.size().width.rounded(.up)
        let imageWidth: CGFloat = image == nil ? 0 : 22
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: max(180, titleWidth + imageWidth + 48),
            height: 22
        ))

        autoresizingMask = [.width]

        selectionImage.imageScaling = .scaleProportionallyDown
        selectionImage.translatesAutoresizingMaskIntoConstraints = false

        optionImage.image = image
        optionImage.imageScaling = .scaleProportionallyDown
        optionImage.isHidden = image == nil
        optionImage.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.title = ""
        actionButton.isBordered = false
        actionButton.isTransparent = true
        actionButton.target = self
        actionButton.action = #selector(performSelection)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setAccessibilityLabel(title.string)
        actionButton.setAccessibilityRole(.button)

        addSubview(selectionImage)
        addSubview(optionImage)
        addSubview(titleLabel)
        addSubview(actionButton)

        let titleLeadingAnchor = image == nil
            ? selectionImage.trailingAnchor
            : optionImage.trailingAnchor

        NSLayoutConstraint.activate([
            selectionImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            selectionImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            selectionImage.widthAnchor.constraint(equalToConstant: 13),
            selectionImage.heightAnchor.constraint(equalToConstant: 13),

            optionImage.leadingAnchor.constraint(
                equalTo: selectionImage.trailingAnchor,
                constant: 5
            ),
            optionImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            optionImage.widthAnchor.constraint(equalToConstant: 16),
            optionImage.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: titleLeadingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateSelection()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered, isActionEnabled else { return }

        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updateSelection() {
        selectionImage.image = isSelected
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
            : nil
        actionButton.setAccessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func updateAppearance() {
        let isHighlighted = isHovered && isActionEnabled
        selectionImage.contentTintColor = isHighlighted
            ? .selectedMenuItemTextColor
            : .labelColor
        if optionImage.image?.isTemplate == true {
            optionImage.contentTintColor = isHighlighted
                ? .selectedMenuItemTextColor
                : .labelColor
        }

        guard isHighlighted else {
            titleLabel.attributedStringValue = normalTitle
            needsDisplay = true
            return
        }

        let highlightedTitle = NSMutableAttributedString(attributedString: normalTitle)
        highlightedTitle.addAttribute(
            .foregroundColor,
            value: NSColor.selectedMenuItemTextColor,
            range: NSRange(location: 0, length: highlightedTitle.length)
        )
        titleLabel.attributedStringValue = highlightedTitle
        needsDisplay = true
    }

    @objc private func performSelection() {
        guard isActionEnabled else { return }
        onSelect()
    }
}
