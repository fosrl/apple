import SwiftUI

struct OnDemandSSIDEditView: View {
    @ObservedObject var viewModel: ActivateOnDemandViewModel
    var onSave: () -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var newSSID = ""

    var body: some View {
        #if os(iOS)
        formContent
            .navigationTitle("Wi-Fi Networks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                }
            }
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text("Wi-Fi Networks")
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
                Section(header: Text("Wi-Fi Networks")) {
                    ForEach(Array(viewModel.selectedSSIDs.enumerated()), id: \.offset) { index, _ in
                        HStack(spacing: 12) {
                            TextField("Wi-Fi Network", text: bindingForSSID(at: index))
                            Button {
                                deleteSSID(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove Wi-Fi Network")
                        }
                    }
                    .onDelete(perform: deleteSSIDs)

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
                        .accessibilityLabel("Add Wi-Fi Network")
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
}
