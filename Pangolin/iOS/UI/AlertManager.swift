//
//  AlertManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

#if os(iOS)
import Foundation
import UIKit
import Combine

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
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        rootViewController.present(alert, animated: true)
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
#endif

