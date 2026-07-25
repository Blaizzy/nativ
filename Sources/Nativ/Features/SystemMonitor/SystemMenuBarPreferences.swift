import Combine
import Foundation

enum SystemMenuBarMetric: String, CaseIterable, Identifiable {
    case nativ
    case cpu
    case gpu
    case ram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativ:
            "Nativ"
        case .cpu:
            "CPU"
        case .gpu:
            "GPU"
        case .ram:
            "Memory"
        }
    }

    var menuBarLabel: String {
        switch self {
        case .ram:
            "MEM"
        default:
            title
        }
    }

    var systemImage: String {
        switch self {
        case .nativ:
            "app.dashed"
        case .cpu:
            "cpu"
        case .gpu:
            "display"
        case .ram:
            "memorychip"
        }
    }

    var menuBarStyles: [SystemMenuBarStyle] {
        switch self {
        case .nativ:
            []
        case .cpu, .gpu:
            [.percentage, .graph]
        case .ram:
            [.percentage, .graph, .gigabytes]
        }
    }
}

enum SystemMenuBarStyle: String, CaseIterable, Identifiable {
    case percentage
    case graph
    case gigabytes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentage:
            "Percentage"
        case .graph:
            "Mini graph"
        case .gigabytes:
            "GB"
        }
    }

    var systemImage: String {
        switch self {
        case .percentage:
            "percent"
        case .graph:
            "chart.xyaxis.line"
        case .gigabytes:
            "memorychip"
        }
    }
}

struct SystemMenuBarItem: Hashable, Identifiable {
    let metric: SystemMenuBarMetric
    let style: SystemMenuBarStyle

    var id: String {
        "\(metric.rawValue).\(style.rawValue)"
    }

    init(metric: SystemMenuBarMetric, style: SystemMenuBarStyle) {
        self.metric = metric
        self.style = style
    }

    init?(id: String) {
        let components = id.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let metric = SystemMenuBarMetric(rawValue: String(components[0])),
              metric != .nativ,
              let style = SystemMenuBarStyle(rawValue: String(components[1])),
              metric.menuBarStyles.contains(style) else {
            return nil
        }
        self.metric = metric
        self.style = style
    }
}

@MainActor
final class SystemMenuBarPreferences: ObservableObject {
    static let shared = SystemMenuBarPreferences()

    @Published private(set) var items: Set<SystemMenuBarItem> {
        didSet {
            defaults.set(items.map(\.id).sorted(), forKey: Self.itemsKey)
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    private static let itemsKey = "systemMenuBarItems"
    private static let metricKey = "systemMenuBarMetric"
    private static let styleKey = "systemMenuBarStyle"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let storedItems = defaults.stringArray(forKey: Self.itemsKey) {
            items = Set(storedItems.compactMap(SystemMenuBarItem.init(id:)))
        } else {
            let legacyMetric = defaults.string(forKey: Self.metricKey)
                .flatMap(SystemMenuBarMetric.init(rawValue:))
                ?? .nativ
            let legacyStyle = defaults.string(forKey: Self.styleKey)
                .flatMap(SystemMenuBarStyle.init(rawValue:))
                ?? .percentage
            if legacyMetric == .nativ {
                items = []
            } else {
                items = [SystemMenuBarItem(
                    metric: legacyMetric,
                    style: legacyStyle
                )]
            }
        }
    }

    var orderedItems: [SystemMenuBarItem] {
        SystemMenuBarMetric.allCases
            .filter { $0 != .nativ }
            .flatMap { metric in
                metric.menuBarStyles.compactMap { style in
                    let item = SystemMenuBarItem(metric: metric, style: style)
                    return items.contains(item) ? item : nil
                }
            }
    }

    func contains(metric: SystemMenuBarMetric, style: SystemMenuBarStyle) -> Bool {
        items.contains(SystemMenuBarItem(metric: metric, style: style))
    }

    func setEnabled(
        _ isEnabled: Bool,
        metric: SystemMenuBarMetric,
        style: SystemMenuBarStyle
    ) {
        guard metric != .nativ, metric.menuBarStyles.contains(style) else {
            return
        }
        var updatedItems = items
        let item = SystemMenuBarItem(metric: metric, style: style)
        if isEnabled {
            updatedItems.insert(item)
        } else {
            updatedItems.remove(item)
        }
        items = updatedItems
    }

    func useNativIcon() {
        items = []
    }
}
