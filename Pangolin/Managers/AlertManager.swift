//
//  AlertManager.swift
//  Pangolin
//
//  Created by Milo Schwartz on 11/5/25.
//

import Foundation
import AppKit
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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

