import Foundation
import Combine

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
class AlertManager: ObservableObject {
    static let shared = AlertManager()
    
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    
    private init() {}
    
    func show(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
    
    func show(error: Error) {
        let title = "Error"
        let message: String
        
        if let apiError = error as? APIError {
            message = apiError.errorDescription ?? error.localizedDescription
        } else {
            message = error.localizedDescription
        }
        
        show(title: title, message: message)
    }
    
    func showAlertDialog(title: String, message: String) {
        #if os(iOS)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        rootViewController.present(alert, animated: true)
        #elseif os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        #endif
    }
    
    func showErrorDialog(_ error: Error) {
        let title = "Error"
        let message: String
        
        if let apiError = error as? APIError {
            message = apiError.errorDescription ?? error.localizedDescription
        } else {
            message = error.localizedDescription
        }
        
        showAlertDialog(title: title, message: message)
    }
}

