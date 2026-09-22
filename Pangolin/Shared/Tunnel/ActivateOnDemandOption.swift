import NetworkExtension
import os.log

enum ActivateOnDemandOption: Equatable {
    case off
    case wiFiInterfaceOnly(ActivateOnDemandSSIDOption)
    case nonWiFiInterfaceOnly
    case anyInterface(ActivateOnDemandSSIDOption)
}

#if os(iOS)
private let nonWiFiInterfaceType: NEOnDemandRuleInterfaceType = .cellular
#elseif os(macOS)
private let nonWiFiInterfaceType: NEOnDemandRuleInterfaceType = .ethernet
#endif

enum ActivateOnDemandSSIDOption: Equatable {
    case anySSID
    case onlySpecificSSIDs([String])
    case exceptSpecificSSIDs([String])
}

extension ActivateOnDemandOption {
    func apply(on tunnelProviderManager: NETunnelProviderManager) {
        let rules: [NEOnDemandRule]?
        switch self {
        case .off:
            rules = nil
        case .wiFiInterfaceOnly(let ssidOption):
            rules =
                ssidOnDemandRules(option: ssidOption)
                + [NEOnDemandRuleDisconnect(interfaceType: nonWiFiInterfaceType)]
        case .nonWiFiInterfaceOnly:
            rules = [
                NEOnDemandRuleConnect(interfaceType: nonWiFiInterfaceType),
                NEOnDemandRuleDisconnect(interfaceType: .wiFi),
            ]
        case .anyInterface(let ssidOption):
            if case .anySSID = ssidOption {
                rules = [NEOnDemandRuleConnect(interfaceType: .any)]
            } else {
                rules =
                    ssidOnDemandRules(option: ssidOption)
                    + [NEOnDemandRuleConnect(interfaceType: nonWiFiInterfaceType)]
            }
        }
        tunnelProviderManager.onDemandRules = rules
        tunnelProviderManager.isOnDemandEnabled =
            (rules != nil) && tunnelProviderManager.isOnDemandEnabled
    }

    init(from tunnelProviderManager: NETunnelProviderManager) {
        if let onDemandRules = tunnelProviderManager.onDemandRules {
            self = ActivateOnDemandOption.create(from: onDemandRules)
        } else {
            self = .off
        }
    }

    private static func create(from rules: [NEOnDemandRule]) -> ActivateOnDemandOption {
        let logger = OSLog(
            subsystem: Bundle.main.bundleIdentifier ?? "net.pangolin.Pangolin",
            category: "ActivateOnDemandOption")

        switch rules.count {
        case 0:
            return .off
        case 1:
            let rule = rules[0]
            guard rule.action == .connect else { return .off }
            return .anyInterface(.anySSID)
        case 2:
            guard let connectRule = rules.first(where: { $0.action == .connect }) else {
                os_log(
                    "Unexpected onDemandRules: %{public}d rules but no connect rule",
                    log: logger, type: .error, rules.count)
                return .off
            }
            guard let disconnectRule = rules.first(where: { $0.action == .disconnect }) else {
                os_log(
                    "Unexpected onDemandRules: %{public}d rules but no disconnect rule",
                    log: logger, type: .error, rules.count)
                return .off
            }
            if connectRule.interfaceTypeMatch == .wiFi
                && disconnectRule.interfaceTypeMatch == nonWiFiInterfaceType
            {
                return .wiFiInterfaceOnly(.anySSID)
            } else if connectRule.interfaceTypeMatch == nonWiFiInterfaceType
                && disconnectRule.interfaceTypeMatch == .wiFi
            {
                return .nonWiFiInterfaceOnly
            } else {
                os_log(
                    "Unexpected onDemandRules: %{public}d rules with inconsistent interface types",
                    log: logger, type: .error, rules.count)
                return .off
            }
        case 3:
            guard
                let ssidRule = rules.first(where: {
                    $0.interfaceTypeMatch == .wiFi && $0.ssidMatch != nil
                })
            else { return .off }
            guard let nonWiFiRule = rules.first(where: { $0.interfaceTypeMatch == nonWiFiInterfaceType })
            else { return .off }
            let ssids = ssidRule.ssidMatch!
            switch (ssidRule.action, nonWiFiRule.action) {
            case (.connect, .connect):
                return .anyInterface(.onlySpecificSSIDs(ssids))
            case (.connect, .disconnect):
                return .wiFiInterfaceOnly(.onlySpecificSSIDs(ssids))
            case (.disconnect, .connect):
                return .anyInterface(.exceptSpecificSSIDs(ssids))
            case (.disconnect, .disconnect):
                return .wiFiInterfaceOnly(.exceptSpecificSSIDs(ssids))
            default:
                os_log(
                    "Unexpected onDemandRules: %{public}d rules with unexpected actions",
                    log: logger, type: .error, rules.count)
                return .off
            }
        default:
            os_log(
                "Unexpected number of onDemandRules: %{public}d",
                log: logger, type: .error, rules.count)
            return .off
        }
    }
}

private extension NEOnDemandRuleConnect {
    convenience init(interfaceType: NEOnDemandRuleInterfaceType, ssids: [String]? = nil) {
        self.init()
        interfaceTypeMatch = interfaceType
        ssidMatch = ssids
    }
}

private extension NEOnDemandRuleDisconnect {
    convenience init(interfaceType: NEOnDemandRuleInterfaceType, ssids: [String]? = nil) {
        self.init()
        interfaceTypeMatch = interfaceType
        ssidMatch = ssids
    }
}

private func ssidOnDemandRules(option: ActivateOnDemandSSIDOption) -> [NEOnDemandRule] {
    switch option {
    case .anySSID:
        return [NEOnDemandRuleConnect(interfaceType: .wiFi)]
    case .onlySpecificSSIDs(let ssids):
        return [
            NEOnDemandRuleConnect(interfaceType: .wiFi, ssids: ssids),
            NEOnDemandRuleDisconnect(interfaceType: .wiFi),
        ]
    case .exceptSpecificSSIDs(let ssids):
        return [
            NEOnDemandRuleDisconnect(interfaceType: .wiFi, ssids: ssids),
            NEOnDemandRuleConnect(interfaceType: .wiFi),
        ]
    }
}
