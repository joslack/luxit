import Foundation

enum OrbDynamicsPreset: String, CaseIterable {
    case turbulent
    case attractor

    private static let defaultsKey = "indicator.orbDynamics"

    var displayName: String {
        switch self {
        case .turbulent: return "Turbulent"
        case .attractor: return "Attractor"
        }
    }

    var detail: String {
        switch self {
        case .turbulent:
            return "Fast, short-scale vortices"
        case .attractor:
            return "Bounded strange-field motion"
        }
    }

    var speedScale: CGFloat {
        switch self {
        case .turbulent: return 1.55
        case .attractor: return 1.08
        }
    }

    var currentScale: CGFloat {
        switch self {
        case .turbulent: return 1.42
        case .attractor: return 0.86
        }
    }

    var jitterScale: CGFloat {
        switch self {
        case .turbulent: return 1.55
        case .attractor: return 0.58
        }
    }

    var spatialScale: CGFloat {
        switch self {
        case .turbulent: return 1.62
        case .attractor: return 1.08
        }
    }

    var attractorBlend: CGFloat {
        self == .attractor ? 1 : 0
    }

    var voiceResponseScale: CGFloat {
        switch self {
        case .turbulent: return 1
        case .attractor: return 1.65
        }
    }

    static var saved: OrbDynamicsPreset {
        guard
            let value = UserDefaults.standard.string(forKey: defaultsKey),
            let preset = OrbDynamicsPreset(rawValue: value)
        else {
            return .turbulent
        }
        return preset
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
