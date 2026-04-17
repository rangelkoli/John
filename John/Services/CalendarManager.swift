import EventKit
import SwiftUI

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined

    private let service = CalendarService()
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.reloadAll() }
        }
        Task { await checkAuthorization() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func checkAuthorization() async {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        calendarAuthorizationStatus = eventStatus
        reminderAuthorizationStatus = reminderStatus

        var needsReload = false
        if eventStatus == .notDetermined {
            if let granted = try? await service.requestAccess(to: .event) {
                calendarAuthorizationStatus = granted ? .fullAccess : .denied
                if granted { needsReload = true }
            }
        } else if eventStatus == .fullAccess {
            needsReload = true
        }

        if reminderStatus == .notDetermined {
            if let granted = try? await service.requestAccess(to: .reminder) {
                reminderAuthorizationStatus = granted ? .fullAccess : .denied
                if granted { needsReload = true }
            }
        } else if reminderStatus == .fullAccess {
            needsReload = true
        }

        if needsReload { await reloadAll() }
    }

    func reloadAll() async {
        allCalendars = await service.calendars()
        if selectedCalendarIDs.isEmpty {
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        }
        await refreshEvents()
    }

    func updateDate(_ date: Date) async {
        currentDate = Calendar.current.startOfDay(for: date)
        await refreshEvents()
    }

    func setCalendarSelected(_ id: String, selected: Bool) async {
        if selected { selectedCalendarIDs.insert(id) }
        else { selectedCalendarIDs.remove(id) }
        await refreshEvents()
    }

    func setReminderCompleted(id: String, completed: Bool) async {
        await service.setReminderCompleted(reminderID: id, completed: completed)
        await refreshEvents()
    }

    private func refreshEvents() async {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        events = await service.events(
            from: currentDate, to: end,
            calendars: Array(selectedCalendarIDs)
        )
    }
}
