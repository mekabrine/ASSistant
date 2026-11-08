import Foundation

enum VoiceCallProgress {
    static func shortPhrase(for status: String) -> String? {
        let lower = status.lowercased()
        if lower.contains("searching the live web") || lower.contains("browser: browser_search") {
            return "I'm searching the web for you now."
        }
        if lower.contains("browser: browser_open") || lower.contains("opening website") {
            return "I'm opening another page to check."
        }
        if lower.contains("browser: browser_follow") {
            return "I'm looking at another promising result."
        }
        if lower.contains("browser: browser_scroll") {
            return "I'm reading further down this page."
        }
        if lower.contains("browser: browser_new") || lower.contains("browser: browser_switch") {
            return "I'm checking this in another browser."
        }
        if lower.contains("browser: browser_request_handoff") || lower.contains("verification") {
            return "I need your help verifying this page."
        }
        if lower.contains("reading findings") {
            return "I'm comparing the information I've found."
        }
        return nil
    }

    static func spokenReply(_ text: String) -> String {
        let withoutURLs = text.replacingOccurrences(
            of: "https?://[^\\s)]+", with: "a linked page",
            options: .regularExpression)
        return String(withoutURLs.prefix(4000))
    }
}
