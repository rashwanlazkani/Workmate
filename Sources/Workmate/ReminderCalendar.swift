import SwiftUI

struct ReminderCalendar: View {
    @Binding var date: Date
    @ViewState<Date> private var month = Date()
    private let calendar = Calendar.current
    private var firstDay: Date { calendar.dateInterval(of: .month, for: month)!.start }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: month)!.count }
    private var leadingDays: Int { (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7 }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(month, format: .dateTime.month(.wide).year()).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                    .modernButtonStyle(shape: .circle).accessibilityLabel("Previous month")
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
                    .modernButtonStyle(shape: .circle).accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(0..<(7 + leadingDays + dayCount), id: \.self) { index in
                    if index < 7 {
                        Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(height: 22).accessibilityHidden(true)
                    } else if index < 7 + leadingDays {
                        Color.clear.frame(height: 32).accessibilityHidden(true)
                    } else {
                    let number = index - 7 - leadingDays + 1
                    let day = calendar.date(byAdding: .day, value: number - 1, to: firstDay)!
                    let selected = calendar.isDate(day, inSameDayAs: date)
                    Button { select(day) } label: {
                        Text("\(number)").font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .background(selected ? Palette.accent : .clear, in: Circle())
                            .overlay { Circle().strokeBorder(calendar.isDateInToday(day) && !selected ? Palette.accent : .clear) }
                            .contentShape(Circle())
                    }.buttonStyle(FullHitButtonStyle())
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }.onAppear { month = date }
    }
    private func moveMonth(_ amount: Int) { month = calendar.date(byAdding: .month, value: amount, to: firstDay)! }
    private func select(_ day: Date) {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        date = calendar.date(bySettingHour: clock.hour ?? 9, minute: clock.minute ?? 0, second: 0, of: day) ?? day
    }
}
