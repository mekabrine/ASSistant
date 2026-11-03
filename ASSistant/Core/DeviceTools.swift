import Foundation
import CoreLocation
import EventKit
import Contacts
import UserNotifications
import UIKit
import AVFoundation

enum DeviceToolError: LocalizedError {
    case denied
    case missingInput
    case unavailable
    var errorDescription: String? {
        switch self {
        case .denied: return "Permission denied. You can change access in iOS Settings."
        case .missingInput: return "Enter the required details for this action."
        case .unavailable: return "This tool is unavailable on this device."
        }
    }
}

@MainActor
final class DeviceTools: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = DeviceTools()
    private let locationManager = CLLocationManager()
    private var locationWaiter: CheckedContinuation<CLLocation, Error>?
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()
    private let speaker = AVSpeechSynthesizer()

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(text.prefix(4000)))
        speaker.speak(utterance)
    }

    func stopSpeaking() { speaker.stopSpeaking(at: .immediate) }

    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else { throw DeviceToolError.unavailable }
        guard locationWaiter == nil else { throw DeviceToolError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            locationWaiter = continuation
            let status = locationManager.authorizationStatus
            if status == .notDetermined { locationManager.requestWhenInUseAuthorization() }
            else if status == .authorizedAlways || status == .authorizedWhenInUse { locationManager.requestLocation() }
            else {
                locationWaiter = nil
                continuation.resume(throwing: DeviceToolError.denied)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationWaiter != nil else { return }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            locationWaiter?.resume(throwing: DeviceToolError.denied)
            locationWaiter = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { locationWaiter?.resume(returning: location) }
        else { locationWaiter?.resume(throwing: DeviceToolError.unavailable) }
        locationWaiter = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationWaiter?.resume(throwing: error)
        locationWaiter = nil
    }

    func authorizeReminders() async throws {
        let granted = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
            eventStore.requestAccess(to: .reminder) { ok, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: ok) }
            }
        }
        guard granted else { throw DeviceToolError.denied }
    }

    func createReminder(title: String, notes: String, due: Date?) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DeviceToolError.missingInput }
        try await authorizeReminders()
        let item = EKReminder(eventStore: eventStore)
        item.title = title
        item.notes = notes
        item.calendar = eventStore.defaultCalendarForNewReminders()
        if let due { item.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        try eventStore.save(item, commit: true)
    }

    func authorizeCalendar() async throws {
        let granted = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
            eventStore.requestAccess(to: .event) { ok, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: ok) }
            }
        }
        guard granted else { throw DeviceToolError.denied }
    }

    func createCalendarEvent(title: String, start: Date, end: Date) async throws {
        guard !title.isEmpty, end > start else { throw DeviceToolError.missingInput }
        try await authorizeCalendar()
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent)
    }

    func contactsCount() async throws -> Int {
        let granted = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, Error>) in
            contactStore.requestAccess(for: .contacts) { ok, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: ok) }
            }
        }
        guard granted else { throw DeviceToolError.denied }
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        var total = 0
        try contactStore.enumerateContacts(with: request) { _, _ in total += 1 }
        return total
    }

    func requestNotifications() async throws {
        let allowed = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
        guard allowed else { throw DeviceToolError.denied }
    }

    func scheduleNotification(id: UUID, title: String, body: String, at date: Date) async throws {
        try await requestNotifications()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    func cancelNotification(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    func copyToClipboard(_ value: String) { UIPasteboard.general.string = value }

    func pasteFromClipboard() -> String { UIPasteboard.general.string ?? "" }
}
