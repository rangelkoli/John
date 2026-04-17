import SwiftUI

private extension Date {
    var dayNumber: Int { Calendar.current.component(.day, from: self) }
}

struct DateWheelPicker: View {
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var byClick = false

    private let past = 7
    private let future = 14
    private let offset = 2

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                let total = past + future + 1
                let totalItems = total + 2 * offset
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < offset || index >= offset + total {
                        Spacer().frame(width: 32, height: 50).id(index)
                    } else {
                        let date = dateForIndex(index)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        dateCell(date: date, isSelected: isSelected, index: index) {
                            selectedDate = date
                            byClick = true
                            withAnimation { scrollPosition = index }
                        }
                    }
                }
            }
            .frame(height: 50)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)
        .onChange(of: scrollPosition) { _, newValue in
            if !byClick, let idx = newValue {
                let total = past + future + 1
                guard (offset..<(offset + total)).contains(idx) else { return }
                let date = dateForIndex(idx)
                if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
                    selectedDate = date
                }
            } else {
                byClick = false
            }
        }
        .onChange(of: selectedDate) { _, newValue in
            let idx = indexForDate(newValue)
            if scrollPosition != idx {
                byClick = true
                withAnimation { scrollPosition = idx }
            }
        }
        .onAppear {
            byClick = true
            scrollPosition = indexForDate(Date())
        }
    }

    private func dateCell(date: Date, isSelected: Bool, index: Int, action: @escaping () -> Void) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return Button(action: action) {
            VStack(spacing: 6) {
                Text(formatter.string(from: date))
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white : Color(white: 0.55))
                ZStack {
                    Circle()
                        .fill(isToday ? Color.accentColor : Color.clear)
                        .frame(width: 22, height: 22)
                    Text("\(date.dayNumber)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? .white : Color(white: isToday ? 0.95 : 0.65))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private func indexForDate(_ date: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -past, to: today) ?? today
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: start, to: target).day ?? 0
        return offset + max(0, min(days, past + future))
    }

    private func dateForIndex(_ index: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -past, to: today) ?? today
        return cal.date(byAdding: .day, value: index - offset, to: start) ?? today
    }
}

struct CalendarView: View {
    @StateObject private var manager = CalendarManager.shared
    @State private var selectedDate = Date()

    var body: some View {
        VStack(spacing: 8) {
            headerRow
            DateWheelPicker(selectedDate: $selectedDate)
            eventList
        }
        .onChange(of: selectedDate) { _, date in
            Task { await manager.updateDate(date) }
        }
        .onAppear {
            Task {
                await manager.updateDate(Date())
                selectedDate = Date()
            }
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedDate.formatted(.dateTime.month(.wide)))
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(selectedDate.formatted(.dateTime.year()))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if manager.calendarAuthorizationStatus != .fullAccess {
                Button("Grant Access") {
                    Task { await manager.checkAuthorization() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 4)
    }

    private var eventList: some View {
        Group {
            let filtered = filteredEvents
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(filtered) { event in
                            Button {
                                if let url = event.calendarAppURL() {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                eventRow(event)
                            }
                            .id(event.id)
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.gray.opacity(0.15))
                        }
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.never)
                    .scrollContentBackground(.hidden)
                    .onAppear { scrollToRelevant(proxy: proxy) }
                    .onChange(of: filtered) { _, _ in scrollToRelevant(proxy: proxy) }
                }
            }
        }
    }

    private var filteredEvents: [EventModel] {
        manager.events.filter { event in
            if case .reminder(let completed) = event.type { return !completed }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title2)
                .foregroundColor(.secondary)
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.primary)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private func scrollToRelevant(proxy: ScrollViewProxy) {
        let now = Date()
        let target = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
            ?? filteredEvents.first(where: { $0.isAllDay })
            ?? filteredEvents.last
        guard let target else { return }
        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: EventModel) -> some View {
        if event.type.isReminder {
            let isCompleted: Bool = {
                if case .reminder(let c) = event.type { return c } else { return false }
            }()
            HStack(spacing: 8) {
                ReminderDot(isOn: Binding(
                    get: { isCompleted },
                    set: { val in Task { await manager.setReminderCompleted(id: event.id, completed: val) } }
                ), color: Color(event.calendar.color))

                Text(event.title)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if !event.isAllDay {
                    Text(event.start, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .opacity(isCompleted ? 0.4 : 1.0)
            .padding(.vertical, 3)
        } else {
            HStack(alignment: .top, spacing: 6) {
                Rectangle()
                    .fill(Color(event.calendar.color))
                    .frame(width: 3)
                    .cornerRadius(1.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    if let loc = event.location, !loc.isEmpty {
                        Text(loc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if event.isAllDay {
                        Text("All-day").font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(event.start, style: .time).font(.caption).foregroundColor(.primary)
                        Text(event.end, style: .time).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .opacity(event.eventStatus == .ended && Calendar.current.isDateInToday(event.start) ? 0.55 : 1.0)
            .padding(.vertical, 3)
        }
    }
}

struct ReminderDot: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 14, height: 14)
                if isOn { Circle().fill(color).frame(width: 8, height: 8) }
            }
        }
        .buttonStyle(.plain)
    }
}
