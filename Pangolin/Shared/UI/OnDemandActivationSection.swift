import SwiftUI

/// On-Demand Activation block shared by macOS and iOS Preferences.
struct OnDemandActivationSection: View {
    @ObservedObject var configManager: ConfigManager
    @ObservedObject var tunnelManager: TunnelManager
    @StateObject private var viewModel: ActivateOnDemandViewModel
    #if os(macOS)
    @State private var showSSIDEditor = false
    #endif

    init(configManager: ConfigManager, tunnelManager: TunnelManager) {
        self.configManager = configManager
        self.tunnelManager = tunnelManager
        _viewModel = StateObject(
            wrappedValue: ActivateOnDemandViewModel(from: configManager.config))
    }

    var body: some View {
        Section(header: Text("Connect Automatically On")) {
            #if os(macOS)
            macOSRows
            #else
            iOSRows
            #endif
        }
        .onChange(of: configManager.config?.onDemandNonWiFiEnabled) { _, _ in
            reloadFromConfig()
        }
        .onChange(of: configManager.config?.onDemandWiFiEnabled) { _, _ in
            reloadFromConfig()
        }
        #if os(macOS)
        .sheet(isPresented: $showSSIDEditor) {
            OnDemandSSIDEditView(
                viewModel: viewModel,
                onSave: { persistAndApply() },
                onDismiss: { showSSIDEditor = false }
            )
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var macOSRows: some View {
        HStack {
            Text(ActivateOnDemandViewModel.nonWiFiInterfaceLabel)
                .font(.system(size: 13))
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.isNonWiFiInterfaceEnabled },
                    set: { newValue in
                        viewModel.isNonWiFiInterfaceEnabled = newValue
                        persistAndApply()
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }

        HStack {
            Text(ActivateOnDemandViewModel.wiFiInterfaceLabel)
                .font(.system(size: 13))
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.isWiFiInterfaceEnabled },
                    set: { newValue in
                        viewModel.isWiFiInterfaceEnabled = newValue
                        if !newValue {
                            viewModel.ssidOption = .any
                        }
                        persistAndApply()
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }

        if viewModel.isWiFiInterfaceEnabled {
            HStack {
                Text(ActivateOnDemandViewModel.ssidsLabel)
                    .font(.system(size: 13))
                Spacer()
                Text(viewModel.localizedSSIDDescription)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Button("Set...") {
                    showSSIDEditor = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        Text(
            "Choose when Pangolin may connect automatically. Tap Connect to enable on-demand; Disconnect disables it."
        )
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }
    #endif

    #if os(iOS)
    @ViewBuilder
    private var iOSRows: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isNonWiFiInterfaceEnabled },
            set: { newValue in
                viewModel.isNonWiFiInterfaceEnabled = newValue
                persistAndApply()
            }
        )) {
            Text(ActivateOnDemandViewModel.nonWiFiInterfaceLabel)
        }
        .tint(.accentColor)

        Toggle(isOn: Binding(
            get: { viewModel.isWiFiInterfaceEnabled },
            set: { newValue in
                viewModel.isWiFiInterfaceEnabled = newValue
                if !newValue {
                    viewModel.ssidOption = .any
                }
                persistAndApply()
            }
        )) {
            Text(ActivateOnDemandViewModel.wiFiInterfaceLabel)
        }
        .tint(.accentColor)

        if viewModel.isWiFiInterfaceEnabled {
            // Push instead of sheet — sheets attached to Form sections dismiss when the
            // parent re-renders (e.g. after the first on-demand preference save).
            NavigationLink {
                OnDemandSSIDEditView(
                    viewModel: viewModel,
                    onSave: { persistAndApply() }
                )
            } label: {
                HStack {
                    Text(ActivateOnDemandViewModel.ssidsLabel)
                    Spacer()
                    Text(viewModel.localizedSSIDDescription)
                        .foregroundColor(.secondary)
                }
            }
        }

        Text(
            "Choose when Pangolin may connect automatically. Tap Connect to enable on-demand; Disconnect disables it."
        )
        .font(.caption)
        .foregroundColor(.secondary)
    }
    #endif

    private func reloadFromConfig() {
        let fresh = ActivateOnDemandViewModel(from: configManager.config)
        viewModel.isNonWiFiInterfaceEnabled = fresh.isNonWiFiInterfaceEnabled
        viewModel.isWiFiInterfaceEnabled = fresh.isWiFiInterfaceEnabled
        viewModel.ssidOption = fresh.ssidOption
        viewModel.selectedSSIDs = fresh.selectedSSIDs
    }

    private func persistAndApply() {
        let option = configManager.setOnDemandSettings(from: viewModel)
        Task {
            await tunnelManager.updateOnDemandSettings(option: option)
        }
    }
}
