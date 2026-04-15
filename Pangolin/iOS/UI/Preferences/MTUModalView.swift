import SwiftUI

struct MTUModalView: View {
    let title: String
    @Binding var mtuValue: String
    @Binding var isPresented: Bool
    let onSave: (String) -> Void
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

    init(title: String, mtuValue: Binding<String>, isPresented: Binding<Bool>, onSave: @escaping (String) -> Void) {
        self.title = title
        self._mtuValue = mtuValue
        self._isPresented = isPresented
        self.onSave = onSave
        self._editedValue = State(initialValue: mtuValue.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("MTU", text: $editedValue)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
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
                    Button(action: {
                        editedValue = String(ConfigManager.defaultTunnelMTU)
                    }) {
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if trimmedValue.isEmpty || isValidMTU(trimmedValue) {
                            onSave(trimmedValue)
                            isPresented = false
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
}
