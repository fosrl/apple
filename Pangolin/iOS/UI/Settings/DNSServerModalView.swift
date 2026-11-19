import SwiftUI

struct DNSServerModalView: View {
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

    init(title: String, initialValue: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.onSave = onSave
        self._editedValue = State(initialValue: initialValue)
    }

    var body: some View {
        Form {
            Section {
                TextField("DNS Server", text: $editedValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .focused($isTextFieldFocused)
            } footer: {
                if showValidationError && !trimmedValue.isEmpty && !IPAddressValidator.isValid(trimmedValue) {
                    Text("Enter an IP address for the DNS server (e.g., 1.1.1.1)")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("Enter an IP address for the DNS server (e.g., 1.1.1.1)")
                        .font(.caption)
                }
            }
            .onChange(of: editedValue) { _, _ in showValidationError = false }

            Section {
                Button {
                    editedValue = "1.1.1.1"
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
                    if IPAddressValidator.isValid(trimmedValue) {
                        onSave(trimmedValue.isEmpty ? "" : trimmedValue)
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
