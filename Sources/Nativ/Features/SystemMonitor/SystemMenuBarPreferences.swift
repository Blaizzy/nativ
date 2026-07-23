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
            "RAM"
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
}

enum SystemMenuBarStyle: String, CaseIterable, Identifiable {
    case percentage
    case graph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percentage:
            "Percentage"
        case .graph:
            "Mini graph"
        }
    }

    var systemImage: String {
        switch self {
        case .percentage:
            "percent"
        case .graph:
            "chart.xyaxis.line"
        }
    }
}

@MainActor
final class SystemMenuBarPreferences: ObservableObject {
    static let shared = SystemMenuBarPreferences()

    @Published var metric: SystemMenuBarMetric {
        didSet {
            defaults.set(metric.rawValue, forKey: Self.metricKey)
            onChange?()
        }
    }

    @Published var style: SystemMenuBarStyle {
        didSet {
            defaults.set(style.rawValue, forKey: Self.styleKey)
            onChange?()
        }
    }

    var onChange: (() -> Void)?

    private static let metricKey = "systemMenuBarMetric"
    private static let styleKey = "systemMenuBarStyle"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        metric = defaults.string(forKey: Self.metricKey)
            .flatMap(SystemMenuBarMetric.init(rawValue:))
            ?? .nativ
        style = defaults.string(forKey: Self.styleKey)
            .flatMap(SystemMenuBarStyle.init(rawValue:))
            ?? .percentage
    }
}
