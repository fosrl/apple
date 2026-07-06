import SwiftUI

struct DNSServerModalView: View {
    let title: String
    @Binding var dnsServer: String
    @Binding var isPresented: Bool
    let onSave: (String) -> Void
    @State private var editedValue: String
    @State private var showValidationError = false
    @FocusState private var isTextFieldFocused: Bool

    private var trimmedValue: String {
        editedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    init(title: String, dnsServer: Binding<String>, isPresented: Binding<Bool>, onSave: @escaping (String) -> Void) {
        self.title = title
        self._dnsServer = dnsServer
        self._isPresented = isPresented
        self.onSave = onSave
        self._editedValue = State(initialValue: dnsServer.wrappedValue)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("DNS Server", text: $editedValue)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
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
                .onChange(of: editedValue) { _ in showValidationError = false }
                
                Section {
                    Button(action: {
                        editedValue = "1.1.1.1"
                    }) {
                        HStack {
                            Spacer()
                            Text("Use Default")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("DNS Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if IPAddressValidator.isValid(trimmedValue) {
                            let value = trimmedValue.isEmpty ? "" : trimmedValue
                            onSave(value)
                            isPresented = false
                        } else {
                            showValidationError = true
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Focus text field when modal appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isTextFieldFocused = true
                }
            }
        }
    }
}
