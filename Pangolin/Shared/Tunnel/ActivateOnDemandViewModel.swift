import Combine
import Foundation

enum OnDemandSSIDOptionKind: String, Codable, CaseIterable {
    case any
    case only
    case except

    var localizedUIString: String {
        switch self {
        case .any: return "Any Wi-Fi Network"
        case .only: return "Only these Wi-Fi Networks"
        case .except: return "Except these Wi-Fi Networks"
        }
    }
}

final class ActivateOnDemandViewModel: ObservableObject {
    @Published var isNonWiFiInterfaceEnabled = false
    @Published var isWiFiInterfaceEnabled = false
    @Published var selectedSSIDs = [String]()
    @Published var ssidOption: OnDemandSSIDOptionKind = .any

    #if os(iOS)
    static let nonWiFiInterfaceLabel = "Cellular"
    #elseif os(macOS)
    static let nonWiFiInterfaceLabel = "Ethernet"
    #endif

    static let wiFiInterfaceLabel = "Wi-Fi"
    static let ssidsLabel = "Wi-Fi Networks"

    init() {}

    init(from config: Config?) {
        isNonWiFiInterfaceEnabled = config?.onDemandNonWiFiEnabled ?? false
        isWiFiInterfaceEnabled = config?.onDemandWiFiEnabled ?? false
        ssidOption = config?.onDemandSSIDOption ?? .any
        selectedSSIDs = config?.onDemandSSIDs ?? []
        fixSSIDOption()
    }

    func toOnDemandOption() -> ActivateOnDemandOption {
        switch (isWiFiInterfaceEnabled, isNonWiFiInterfaceEnabled) {
        case (false, false):
            return .off
        case (false, true):
            return .nonWiFiInterfaceOnly
        case (true, false):
            return .wiFiInterfaceOnly(toSSIDOption())
        case (true, true):
            return .anyInterface(toSSIDOption())
        }
    }

    var localizedInterfaceDescription: String {
        switch (isWiFiInterfaceEnabled, isNonWiFiInterfaceEnabled) {
        case (false, false):
            return "Off"
        case (true, false):
            return "Wi-Fi only"
        case (false, true):
            #if os(iOS)
            return "Cellular only"
            #elseif os(macOS)
            return "Ethernet only"
            #endif
        case (true, true):
            #if os(iOS)
            return "Wi-Fi or cellular"
            #elseif os(macOS)
            return "Wi-Fi or ethernet"
            #endif
        }
    }

    var localizedSSIDDescription: String {
        guard isWiFiInterfaceEnabled else { return "" }
        switch ssidOption {
        case .any:
            return "Any Wi-Fi Network"
        case .only:
            let count = selectedSSIDs.count
            return count == 1 ? "Only 1 Wi-Fi Network" : "Only \(count) Wi-Fi Networks"
        case .except:
            let count = selectedSSIDs.count
            return count == 1 ? "Except 1 Wi-Fi Network" : "Except \(count) Wi-Fi Networks"
        }
    }

    func fixSSIDOption() {
        selectedSSIDs = uniquifiedNonEmptySelectedSSIDs()
        if selectedSSIDs.isEmpty {
            ssidOption = .any
        }
    }

    func apply(to config: inout Config) {
        fixSSIDOption()
        config.onDemandNonWiFiEnabled = isNonWiFiInterfaceEnabled
        config.onDemandWiFiEnabled = isWiFiInterfaceEnabled
        config.onDemandSSIDOption = ssidOption
        config.onDemandSSIDs = selectedSSIDs.isEmpty ? nil : selectedSSIDs
    }

    private func toSSIDOption() -> ActivateOnDemandSSIDOption {
        switch ssidOption {
        case .any:
            return .anySSID
        case .only:
            let ssids = uniquifiedNonEmptySelectedSSIDs()
            return ssids.isEmpty ? .anySSID : .onlySpecificSSIDs(ssids)
        case .except:
            let ssids = uniquifiedNonEmptySelectedSSIDs()
            return ssids.isEmpty ? .anySSID : .exceptSpecificSSIDs(ssids)
        }
    }

    private func uniquifiedNonEmptySelectedSSIDs() -> [String] {
        let nonEmptySSIDs = selectedSSIDs.filter { !$0.isEmpty }
        var seenSSIDs = Set<String>()
        var uniquified = [String]()
        for ssid in nonEmptySSIDs {
            guard !seenSSIDs.contains(ssid) else { continue }
            uniquified.append(ssid)
            seenSSIDs.insert(ssid)
        }
        return uniquified
    }
}
