//
//  DNSServerModalView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import SwiftUI

struct DNSServerModalView: View {
    let title: String
    @Binding var dnsServer: String
    @Binding var isPresented: Bool
    let onSave: (String) -> Void
    @State private var editedValue: String
    @FocusState private var isTextFieldFocused: Bool
    
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
                    Text("Enter an IP address for the DNS server (e.g., 1.1.1.1)")
                        .font(.caption)
                }
                
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
                        onSave(editedValue.isEmpty ? "" : editedValue)
                        isPresented = false
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
#endif

