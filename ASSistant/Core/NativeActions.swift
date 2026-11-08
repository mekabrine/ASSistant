import Foundation
import SwiftUI
import MessageUI
import Contacts
import UIKit

struct SMSDraft: Identifiable {
    let id = UUID()
    var recipient: String
    var message: String
}

enum NativeActionError: LocalizedError {
    case invalidNumber
    case invalidShortcut
    case messagesUnavailable
    case openFailed
    case contactAccessDenied

    var errorDescription: String? {
        switch self {
        case .invalidNumber: return "A valid phone number is required."
        case .invalidShortcut: return "Enter the exact name of a Shortcut installed on this iPhone."
        case .messagesUnavailable: return "This device cannot compose Messages with the system app."
        case .openFailed: return "iOS could not open the requested Phone or Shortcuts action."
        case .contactAccessDenied: return "Contacts permission was not granted."
        }
    }
}

@MainActor
enum NativeActions {
    static func cleanPhone(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 28,
              value.range(of: #"^\+?[0-9().\s-]+$"#, options: .regularExpression) != nil else {
            throw NativeActionError.invalidNumber
        }
        let digits = value.filter { $0.isNumber }
        guard (7...15).contains(digits.count) else { throw NativeActionError.invalidNumber }
        return (value.hasPrefix("+") ? "+" : "") + digits
    }

    static func openPhone(_ number: String) async throws -> String {
        let sanitized = try cleanPhone(number)
        guard let url = URL(string: "tel:" + sanitized) else {
            throw NativeActionError.invalidNumber
        }
        guard await UIApplication.shared.open(url) else {
            throw NativeActionError.openFailed
        }
        return "Opened the iOS Phone call request for \(sanitized). The user controls whether the call is placed; call completion is not observable."
    }

    static func runShortcut(name: String, input: String? = nil) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 150, !clean.contains("\n"),
              !clean.contains("\r") else { throw NativeActionError.invalidShortcut }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: clean)]
        if let input, !input.isEmpty {
            items += [URLQueryItem(name: "input", value: "text"),
                      URLQueryItem(name: "text", value: String(input.prefix(12000)))]
        }
        components.queryItems = items
        guard let url = components.url, await UIApplication.shared.open(url) else {
            throw NativeActionError.openFailed
        }
        return "Opened Shortcuts with a request to run “\(clean)”. iOS may require a prompt, and ASSistant cannot verify completion or inspect all installed Shortcuts."
    }

    static func contactMatches(_ name: String) async throws -> String {
        let query = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !query.isEmpty else { throw DeviceToolError.missingInput }
        let contacts = CNContactStore()
        let allowed = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, Error>) in
            contacts.requestAccess(for: .contacts) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
        guard allowed else { throw NativeActionError.contactAccessDenied }
        let matches = try contacts.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: query),
            keysToFetch: [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
        )
        if matches.isEmpty { return "No local contacts matched \(query)." }
        return matches.prefix(6).map { contact in
            let name = [contact.givenName, contact.familyName].joined(separator: " ")
            let numbers = contact.phoneNumbers.prefix(3).map { $0.value.stringValue }
                .joined(separator: ", ")
            return "\(name): \(numbers.isEmpty ? "No stored phone number" : numbers)"
        }.joined(separator: "\n")
    }
}

/// iOS does NOT let third-party apps silently send SMS/iMessage. Users approve
/// each send inside Apple's message composer; cancellation must be surfaced.
struct MessageComposeSheet: UIViewControllerRepresentable {
    let draft: SMSDraft
    let onFinish: (String) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = [draft.recipient]
        controller.body = draft.message
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (String) -> Void

        init(onFinish: @escaping (String) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            let value: String
            switch result {
            case .sent:
                value = "User tapped Send in the system Messages composer. Delivery is not guaranteed."
            case .cancelled:
                value = "User cancelled the Messages composer. No message was sent."
            case .failed:
                value = "Messages reported a failure. No successful send was confirmed."
            @unknown default:
                value = "Messages composer finished with an unknown result."
            }
            controller.dismiss(animated: true) {
                self.onFinish(value)
            }
        }
    }
}
