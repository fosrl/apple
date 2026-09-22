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

            if viewModel.ssidOption != .any {
                Section(header: Text("SSIDs")) {
                    ForEach(Array(viewModel.selectedSSIDs.enumerated()), id: \.offset) { index, ssid in
                        TextField("SSID", text: bindingForSSID(at: index))
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
                        Button("Add") {
                            addNewSSID()
                        }
                        .disabled(newSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
