//
//  DNSServerModalView.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import SwiftUI
import AppKit

struct DNSServerModalView: View {
    let title: String
    @Binding var dnsServer: String
    @Binding var isPresented: Bool
    let onSave: (String) -> Void
    @State private var editedValue: String
    @State private var showValidationError = false

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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.system(size: 13))
                    Spacer()
                }
                
                TextField("", text: $editedValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .onChange(of: editedValue) { _ in showValidationError = false }
                
                if showValidationError && !trimmedValue.isEmpty && !IPAddressValidator.isValid(trimmedValue) {
                    Text("Enter an IP address for the DNS server (e.g., 1.1.1.1)")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }
            .padding(20)
            .onAppear {
                // Update editedValue from binding when modal appears
                editedValue = dnsServer
            }
            
            Divider()
            
            HStack(spacing: 12) {
                Button("Default") {
                    editedValue = "1.1.1.1"
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Button("Done") {
                    if IPAddressValidator.isValid(trimmedValue) {
                        let value = trimmedValue.isEmpty ? "" : trimmedValue
                        onSave(value)
                        isPresented = false
                    } else {
                        showValidationError = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(20)
        }
        .frame(width: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
    }
}

