import SwiftUI
import AppKit

struct MTUModalView: View {
    let title: String
    @Binding var mtuValue: String
    @Binding var isPresented: Bool
    let onSave: (String) -> Void
    @State private var editedValue: String
    @State private var showValidationError = false

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
                    .onChange(of: editedValue) { _, _ in showValidationError = false }

                if showValidationError && !trimmedValue.isEmpty && !isValidMTU(trimmedValue) {
                    Text("Enter an integer between 576 and 65535 (e.g., 1280)")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                } else {
                    Text("Enter an integer between 576 and 65535 (e.g., 1280)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
            .onAppear {
                editedValue = mtuValue
            }

            Divider()

            HStack(spacing: 12) {
                Button("Default") {
                    editedValue = String(ConfigManager.defaultTunnelMTU)
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
                    if trimmedValue.isEmpty || isValidMTU(trimmedValue) {
                        onSave(trimmedValue)
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
