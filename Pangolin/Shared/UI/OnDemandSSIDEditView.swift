import NetworkExtension
import SwiftUI

#if os(macOS)
import CoreWLAN
#endif

struct OnDemandSSIDEditView: View {
    @ObservedObject var viewModel: ActivateOnDemandViewModel
    var connectedSSID: String?
    var onSave: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var newSSID = ""
    @State private var resolvedConnectedSSID: String?

    private var effectiveConnectedSSID: String? {
        resolvedConnectedSSID ?? connectedSSID
    }

    var body: some View {
        #if os(iOS)
        formContent
            .navigationTitle("SSIDs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                }
            }
            .onAppear { refreshConnectedSSIDIfNeeded() }
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text("SSIDs")
                .font(.headline)
            formContent
            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss?()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    saveAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 320)
        .onAppear { refreshConnectedSSIDIfNeeded() }
        #endif
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            #if os(macOS)
            Section {
                Picker(selection: $viewModel.ssidOption) {
                    ForEach(OnDemandSSIDOptionKind.allCases, id: \.self) { kind in
                        Text(kind.localizedUIString).tag(kind)
                    }
                } label: {
                    Text("Matching")
                }
                .pickerStyle(.menu)
            }
            #else
            Section {
                ForEach(OnDemandSSIDOptionKind.allCases, id: \.self) { kind in
                    Button {
                        viewModel.ssidOption = kind
                    } label: {
                        HStack {
                            Text(kind.localizedUIString)
                            Spacer()
                            if viewModel.ssidOption == kind {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
                }
            }
            #endif

            if viewModel.ssidOption != .any {
                Section(header: Text("SSIDs")) {
                    ForEach(Array(viewModel.selectedSSIDs.enumerated()), id: \.offset) { index, _ in
                        HStack(spacing: 12) {
                            TextField("SSID", text: bindingForSSID(at: index))
                            Button {
                                deleteSSID(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove SSID")
                        }
                    }
                    .onDelete(perform: deleteSSIDs)

                    if let effectiveConnectedSSID,
                        !viewModel.selectedSSIDs.contains(effectiveConnectedSSID)
                    {
                        Button("Add connected: \(effectiveConnectedSSID)") {
                            viewModel.selectedSSIDs.append(effectiveConnectedSSID)
                        }
                    }

                    HStack {
                        TextField("Add new", text: $newSSID)
                            .onSubmit(addNewSSID)
                        Button {
                            addNewSSID()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.large)
                        }
                        .buttonStyle(.borderless)
                        .disabled(newSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add SSID")
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private func bindingForSSID(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard viewModel.selectedSSIDs.indices.contains(index) else { return "" }
                return viewModel.selectedSSIDs[index]
            },
            set: { newValue in
                guard viewModel.selectedSSIDs.indices.contains(index) else { return }
                viewModel.selectedSSIDs[index] = newValue
            }
        )
    }

    private func deleteSSIDs(at offsets: IndexSet) {
        viewModel.selectedSSIDs.remove(atOffsets: offsets)
    }

    private func deleteSSID(at index: Int) {
        guard viewModel.selectedSSIDs.indices.contains(index) else { return }
        viewModel.selectedSSIDs.remove(at: index)
    }

    private func addNewSSID() {
        let trimmed = newSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !viewModel.selectedSSIDs.contains(trimmed) {
            viewModel.selectedSSIDs.append(trimmed)
        }
        newSSID = ""
    }

    private func saveAndDismiss() {
        viewModel.fixSSIDOption()
        onSave()
        #if os(iOS)
        dismiss()
        #else
        onDismiss?()
        #endif
    }

    private func refreshConnectedSSIDIfNeeded() {
        guard resolvedConnectedSSID == nil else { return }
        #if os(iOS)
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { network in
                DispatchQueue.main.async {
                    resolvedConnectedSSID = network?.ssid
                }
            }
        }
        #elseif os(macOS)
        resolvedConnectedSSID = CWWiFiClient.shared().interface()?.ssid()
        #endif
    }
}
