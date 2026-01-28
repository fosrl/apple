import Foundation
import Darwin

enum IPAddressValidator {
    /// Returns true if the string is empty/whitespace-only or a valid IPv4 or IPv6 address.
    static func isValid(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.withCString { cString in
            var addr = in_addr()
            if inet_pton(AF_INET, cString, &addr) == 1 { return true }
            var addr6 = in6_addr()
            return inet_pton(AF_INET6, cString, &addr6) == 1
        }
    }
}
