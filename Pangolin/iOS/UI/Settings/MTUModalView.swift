import SwiftUI

struct MTUModalView: View {
    let title: String
    let initialValue: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedValue: String
    @State private var showValidationError = false
    @FocusState private var isTextFieldFocused: Bool

    private var trimmedValue: String {
        editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let mtuRange = 576...65535

    private func isValidMTU(_ string: String) -> Bool {
        guard let mtu = Int(string) else { return false }
        return Self.mtuRange.contains(mtu)
    }

    init(title: String, initialValue: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.onSave = onSave
        self._editedValue = State(initialValue: initialValue)
    }

    var body: some View {
        Form {
            Section {
                TextField("MTU", text: $editedValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
                    .focused($isTextFieldFocused)
            } footer: {
                if showValidationError && !trimmedValue.isEmpty && !isValidMTU(trimmedValue) {
                    Text("Enter an integer between 576 and 65535 (e.g., 1280)")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("Enter an integer between 576 and 65535 (e.g., 1280)")
                        .font(.caption)
                }
            }
            .onChange(of: editedValue) { _, _ in showValidationError = false }

            Section {
                Button {
                    editedValue = String(ConfigManager.defaultTunnelMTU)
                } label: {
                    HStack {
                        Spacer()
                        Text("Use Default")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if trimmedValue.isEmpty || isValidMTU(trimmedValue) {
                        onSave(trimmedValue)
                        dismiss()
                    } else {
                        showValidationError = true
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isTextFieldFocused = true
            }
        }
    }
}
