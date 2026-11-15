import SwiftUI

/// Clock/bell flyout: Windows 11 notification center (top) and calendar (bottom).
struct CalendarFlyout: View {
    @ObservedObject private var store = NotificationStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Notifications").font(Theme.font(14, .semibold))
                    Spacer()
                    if !store.items.isEmpty {
                        Button("Clear all") { store.clearAll() }.buttonStyle(.link).font(Theme.font(12))
                    }
                }
                if store.items.isEmpty {
                    VStack(spacing: 6) {
                        Text("No new notifications").foregroundStyle(Theme.secondaryText(scheme))
                        if !Permissions.shared.accessibility {
                            Text("Allow Accessibility so Fenestra can collect notifications as they arrive.")
                                .font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.items) { NotificationCard(item: $0) }
                        }
                    }
                    .frame(height: min(CGFloat(store.items.count) * 78, 320))
                }
                Button("Open macOS Notification Center") {
                    FlyoutManager.shared.close(animated: false)
                    SystemActions.openNotificationCenter()
                }
                .buttonStyle(.link).font(Theme.font(12))
            }
            .padding(16)

            Rectangle().fill(Theme.border(scheme)).frame(height: 1)

            VStack(spacing: 0) {
                Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(Theme.font(14, .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                Rectangle().fill(Theme.border(scheme)).frame(height: 1)
                MonthGrid(month: $month).padding(12)
            }
        }
        .frame(width: 340)
    }
}

struct NotificationCard: View {
    let item: NotificationStore.Item
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon = NotificationStore.shared.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.badge").frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.app).font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                    Spacer()
                    Text(item.date, style: .time).font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                }
                Text(item.title).font(Theme.font(13, .semibold)).lineLimit(1)
                if !item.body.isEmpty { Text(item.body).font(Theme.font(12)).lineLimit(2) }
            }
            if hovering {
                Button { NotificationStore.shared.remove(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover(scheme).opacity(1.6) : Theme.control(scheme)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            FlyoutManager.shared.close()
            NotificationStore.shared.open(item)
        }
    }
}

struct MonthGrid: View {
    @Binding var month: Date
    @Environment(\.colorScheme) private var scheme
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(month, format: .dateTime.month(.wide).year()).font(Theme.font(13, .semibold))
                Spacer()
                arrow("chevron.up") { shift(-1) }
                arrow("chevron.down") { shift(1) }
            }
            .padding(.bottom, 4)
            HStack(spacing: 0) {
                ForEach(rotatedWeekdaySymbols(), id: \.self) { Text($0).font(Theme.font(12)).frame(maxWidth: .infinity) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(days(), id: \.self) { day in
                    let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
                    let today = cal.isDateInToday(day)
                    Text("\(cal.component(.day, from: day))")
                        .font(Theme.font(13))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(today ? Theme.accent : .clear))
                        .foregroundStyle(today ? (scheme == .dark ? Color.black : Color.white)
                                         : (inMonth ? Theme.text(scheme) : Theme.secondaryText(scheme).opacity(0.6)))
                }
            }
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        if let d = cal.date(byAdding: .month, value: n, to: month) { month = d }
    }

    private func rotatedWeekdaySymbols() -> [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }

    /// Six full weeks starting on the locale's first weekday, like Windows.
    private func days() -> [Date] {
        let firstOfMonth = cal.dateInterval(of: .month, for: month)!.start
        let weekday = cal.component(.weekday, from: firstOfMonth)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: firstOfMonth)!
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}
