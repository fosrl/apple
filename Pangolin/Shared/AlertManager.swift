import Foundation
import Combine

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import UserNotifications
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

    #if os(macOS)
    /// Posts a banner for a failed connection. Falls back to a modal alert when
    /// notifications are denied or the request cannot be delivered.
    func showConnectionErrorNotification(title: String, message: String) async {
        let center = UNUserNotificationCenter.current()
        let authorized: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }

        guard authorized else {
            showAlertDialog(title: title, message: message)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "connection-error",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            showAlertDialog(title: title, message: message)
        }
    }
    #endif
}

