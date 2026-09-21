import AppIntents
import SwiftUI
import WidgetKit

struct PangolinVPNControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: VPNWidgetStatusStore.controlKind,
            provider: PangolinVPNControlValueProvider()
        ) { isOn in
            ControlWidgetToggle(
                "Pangolin",
                isOn: isOn,
                action: TogglePangolinVPNControlIntent()
            ) { isOn in
                Label(
                    isOn ? "Connected" : "Disconnected",
                    image: "PangolinSymbol"
                )
            }
        }
        .displayName("Pangolin")
        .description("Connect or disconnect Pangolin.")
    }
}

struct PangolinVPNControlValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        VPNWidgetStatusStore.read().showsDisconnectButton
    }
}
