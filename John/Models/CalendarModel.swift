import AppKit

struct CalendarModel: Identifiable {
    let id: String
    let account: String
    let title: String
    let color: NSColor
    let isSubscribed: Bool
    let isReminder: Bool
}

extension CalendarModel: Equatable {
    static func == (lhs: CalendarModel, rhs: CalendarModel) -> Bool { lhs.id == rhs.id }
}
