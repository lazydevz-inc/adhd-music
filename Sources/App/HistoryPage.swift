import SwiftUI

/// History in the grown panel. The week strip on top, then the chosen day: its timetable on the
/// left (blocks the length of each stretch, pauses hatched, a line for now) and what it was spent on and
/// listened to on the right. Week / Month swaps the strip for a month calendar. Numbers appear once, in the
/// line above the strip.
struct HistoryView: View {
    @ObservedObject var c: FocusController
    @ObservedObject var settings: AppSettings
    @ObservedObject var ledger: LedgerStore
    @ObservedObject var library: LibraryStore

    @State private var selected: Date?
    @State private var monthAnchor: Date?
    @State private var focusTask: String?
    @State private var cardBlock: UUID?
    @State private var showDayStart = false
    @State private var undo: Undo?

    struct Undo: Equatable {
        let id = UUID()
        let entries: [PlayEntry]
        let text: String
        static func == (a: Undo, b: Undo) -> Bool { a.id == b.id }
    }

    private var cal: Calendar { Calendar.current }
    private var s: Strings { c.strings }
    private var today: Date { LedgerStore.dayLabel(for: c.now, startHour: settings.dayStartHour) }
    private var day: Date { selected ?? c.historyDay ?? today }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 16).padding(.horizontal, 20)
                .frame(height: 44, alignment: .bottom)
            if c.historyMonth {
                monthBody.padding(.top, 10)
            } else {
                WeekStrip(days: weekDays, selected: day, today: today, value: { daySeconds($0) },
                          segments: { stripSegments($0) }, s: s) { pick($0) }
                    .padding(.horizontal, 20).padding(.top, 10)
                weekBody.padding(.top, 14)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { undoToast }
        .onAppear {
            if let start = c.historyDay { selected = start }
            if c.options.preview == "history-daystart" { showDayStart = true }
            if c.options.preview == "history-month-prev" { monthAnchor = cal.date(byAdding: .month, value: -1, to: startOfMonth(today)) }
            if c.options.preview == "history-card" { cardBlock = dayBlocks(day).blocks.first(where: { !$0.live && $0.seconds >= 60 })?.id }
        }
        .onChange(of: c.historyDay) { if let d = c.historyDay { selected = d; c.historyMonth = false } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(periodTitle).font(AppFont.pageTitle).lineLimit(1).padding(.trailing, 4)
            RoundIconButton(systemName: "chevron.left", label: s.prevMonth, size: 12, weight: .semibold, diameter: 26, quiet: true) { step(-1) }
            RoundIconButton(systemName: "chevron.right", label: s.nextMonth, size: 12, weight: .semibold, diameter: 26, quiet: true) { step(1) }
                .disabled(!canStepForward)
            if !showsToday {
                Button(s.todayButton) { goToday() }
                    .buttonStyle(.plain).font(AppFont.bodyStrong).foregroundStyle(Palette.accentText)
                    .padding(.horizontal, 8).frame(height: 26)
                    .hoverFill(RoundedRectangle(Radius.control))
            }
            Spacer(minLength: 12)
            totalsLine
            Segmented(options: [(false, s.week), (true, s.month)], selection: c.historyMonth, hPadding: 12) { month in
                if month { monthAnchor = startOfMonth(day) }
                c.historyMonth = month
                cardBlock = nil
                showDayStart = false
            }
            .padding(.leading, 12)
        }
    }

    private var totalsLine: some View {
        let range = periodDays.filter { $0 <= today }
        let total = range.reduce(0) { $0 + daySeconds($1) }
        let played = range.filter { daySeconds($0) >= 60 }.count
        let avg = played > 0 ? total / Double(played) : 0
        let previous = previousPeriodDays.reduce(0) { $0 + daySeconds($1) }
        let monthBefore = cal.date(byAdding: .month, value: -1, to: monthAnchor ?? startOfMonth(day)) ?? today
        // Nothing to compare with (before the app was used) shows nothing rather than "0m".
        let compare: String? = previous < 60 ? nil
            : c.historyMonth ? s.monthTotal(Fmt.monthOnly(monthBefore, ko: settings.ko), Fmt.duration(previous, ko: settings.ko))
            : s.lastWeekTotal(Fmt.duration(previous, ko: settings.ko))
        return HStack(spacing: 0) {
            Text(s.total + " ").foregroundStyle(.secondary)
            Text(Fmt.duration(total, ko: settings.ko)).fontWeight(.semibold)
            Text("  ·  ").foregroundStyle(.tertiary)
            Text(s.dailyAvg + " ").foregroundStyle(.secondary)
            Text(Fmt.duration(avg, ko: settings.ko)).fontWeight(.semibold)
            if let compare {
                Text("  ·  ").foregroundStyle(.tertiary)
                Text(compare).foregroundStyle(.secondary)
            }
        }
        .font(AppFont.body)
        .monospacedDigit()
        .lineLimit(1)
    }

    // MARK: Week

    private var weekBody: some View {
        HStack(alignment: .top, spacing: 20) {
            DayColumn(day: day, today: today, now: c.now, data: dayBlocks(day), seconds: daySeconds(day),
                      focusTask: focusTask, cardBlock: $cardBlock, library: library, ledger: ledger, s: s,
                      onDeleted: { entries, text in showUndo(entries, text) })
                .frame(width: 330, height: 351)
            DaySummary(data: dayBlocks(day), library: library, settings: settings, s: s,
                       focusTask: $focusTask, showDayStart: $showDayStart)
                .frame(maxWidth: .infinity, maxHeight: 351, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
    }

    private var weekDays: [Date] {
        let start = startOfWeek(day)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func pick(_ d: Date) {
        guard d <= today else { return }
        selected = d
        focusTask = nil
        cardBlock = nil
        showDayStart = false
    }

    // MARK: Month

    private var monthBody: some View {
        let anchor = monthAnchor ?? startOfMonth(day)
        return HStack(alignment: .top, spacing: 20) {
            MonthCalendar(month: anchor, today: today, weekStart: settings.weekStart, s: s,
                          value: { daySeconds($0) }) { d in
                pick(d)
                c.historyMonth = false
            }
            .frame(width: 330)
            MonthSummary(days: monthDays(anchor).filter { $0 <= today }, monthName: Fmt.monthOnly(anchor, ko: settings.ko),
                         ledger: ledger, settings: settings, now: c.now, s: s)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
    }

    // MARK: Periods

    private var periodDays: [Date] { c.historyMonth ? monthDays(monthAnchor ?? startOfMonth(day)) : weekDays }

    private var previousPeriodDays: [Date] {
        if c.historyMonth {
            let anchor = monthAnchor ?? startOfMonth(day)
            return monthDays(cal.date(byAdding: .month, value: -1, to: anchor) ?? anchor)
        }
        return weekDays.compactMap { cal.date(byAdding: .day, value: -7, to: $0) }
    }

    private var periodTitle: String {
        if c.historyMonth { return Fmt.month(monthAnchor ?? startOfMonth(day), ko: settings.ko) }
        let days = weekDays
        let offset = cal.dateComponents([.day], from: startOfWeek(today), to: days[0]).day.map { $0 / 7 } ?? 0
        return s.weekTitle(rangeText(days[0], days[6]), offset: offset)
    }

    private var showsToday: Bool { periodDays.contains { cal.isDate($0, inSameDayAs: today) } }
    private var canStepForward: Bool { !showsToday }

    private func step(_ direction: Int) {
        cardBlock = nil
        showDayStart = false
        if c.historyMonth {
            let anchor = monthAnchor ?? startOfMonth(day)
            monthAnchor = cal.date(byAdding: .month, value: direction, to: anchor)
            return
        }
        guard let moved = cal.date(byAdding: .day, value: 7 * direction, to: day) else { return }
        selected = min(moved, today)
        focusTask = nil
    }

    private func goToday() {
        selected = today
        monthAnchor = startOfMonth(today)
        focusTask = nil
    }

    private func rangeText(_ a: Date, _ b: Date) -> String {
        let sameMonth = cal.isDate(a, equalTo: b, toGranularity: .month)
        let f = DateFormatter()
        f.locale = Locale(identifier: settings.ko ? "ko_KR" : "en_US")
        if settings.ko {
            f.dateFormat = "M월 d일"
            let end = sameMonth ? "\(cal.component(.day, from: b))일" : f.string(from: b)
            f.dateFormat = sameMonth ? "M월 d" : "M월 d일"
            return f.string(from: a) + "–" + end
        }
        f.dateFormat = "MMM d"
        let end = sameMonth ? "\(cal.component(.day, from: b))" : f.string(from: b)
        return f.string(from: a) + (sameMonth ? "–" : " – ") + end
    }

    // MARK: Data

    private func interval(_ d: Date) -> DateInterval { LedgerStore.dayInterval(forLabel: d, startHour: settings.dayStartHour) }
    private func daySeconds(_ d: Date) -> TimeInterval { d > today ? 0 : ledger.seconds(in: interval(d), now: c.now) }
    private func dayBlocks(_ d: Date) -> (blocks: [WorkBlock], pauses: [DayRow]) { ledger.blocks(in: interval(d), now: c.now) }

    /// Where the day's stretches sit on the strip's little band (18 hours from the day start, like Today).
    private func stripSegments(_ d: Date) -> [ClosedRange<Double>] {
        guard d <= today else { return [] }
        let start = interval(d).start
        let span: TimeInterval = 18 * 3600
        return dayBlocks(d).blocks.compactMap { b in
            let a = b.start.timeIntervalSince(start) / span, z = b.end.timeIntervalSince(start) / span
            guard z > 0, a < 1 else { return nil }
            return max(0, a)...min(1, z)
        }
    }

    private func startOfWeek(_ d: Date) -> Date {
        let weekday = cal.component(.weekday, from: d)
        let offset = settings.weekStart == .monday ? (weekday + 5) % 7 : weekday - 1
        return cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: d)) ?? d
    }

    private func startOfMonth(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }

    private func monthDays(_ anchor: Date) -> [Date] {
        let range = cal.range(of: .day, in: .month, for: anchor) ?? 1..<31
        return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: anchor) }
    }

    // MARK: Undo

    private func showUndo(_ entries: [PlayEntry], _ text: String) {
        let item = Undo(entries: entries, text: text)
        withAnimation(.easeOut(duration: 0.2)) { undo = item }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if undo == item { withAnimation(.easeOut(duration: 0.2)) { undo = nil } }
        }
    }

    @ViewBuilder private var undoToast: some View {
        if let undo {
            HStack(spacing: 10) {
                Text(undo.text).lineLimit(1)
                Button(s.undo) {
                    ledger.restorePlays(undo.entries)
                    withAnimation(.easeOut(duration: 0.2)) { self.undo = nil }
                }
                .buttonStyle(.pill(.onDark))
            }
            .font(AppFont.body)
            .foregroundStyle(.white)
            .padding(.leading, 14).padding(.trailing, 4).frame(height: 34)
            .background(Capsule().fill(Palette.toast))
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Week strip

/// Seven day tiles: the day, its time, and a little band showing when in the day the music played.
private struct WeekStrip: View {
    let days: [Date]
    let selected: Date
    let today: Date
    let value: (Date) -> TimeInterval
    let segments: (Date) -> [ClosedRange<Double>]
    let s: Strings
    let onPick: (Date) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, d in
                DayTile(day: d, weekday: weekdayName(d), seconds: value(d), segments: segments(d),
                        isSelected: Calendar.current.isDate(d, inSameDayAs: selected),
                        isToday: Calendar.current.isDate(d, inSameDayAs: today), isFuture: d > today, s: s) { onPick(d) }
            }
        }
        .frame(height: 80)
    }

    private func weekdayName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: s.ko ? "ko_KR" : "en_US")
        f.dateFormat = s.ko ? "E" : "EEE"
        return f.string(from: d)
    }
}

private struct DayTile: View {
    let day: Date
    let weekday: String
    let seconds: TimeInterval
    let segments: [ClosedRange<Double>]
    let isSelected: Bool
    let isToday: Bool
    let isFuture: Bool
    let s: Strings
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(weekday).font(isToday ? AppFont.captionStrong : AppFont.caption).foregroundStyle(.secondary)
                    Text("\(Calendar.current.component(.day, from: day))").font(AppFont.labelStrong)
                        .foregroundStyle(isToday ? AnyShapeStyle(Palette.accentText) : AnyShapeStyle(.primary))
                    if isToday { Text(s.todayTag).font(AppFont.microStrong).foregroundStyle(Palette.accentText) }
                }
                Text(seconds >= 60 ? Fmt.hm(seconds) : "—")
                    .font(AppFont.stat).monospacedDigit()
                    .foregroundStyle(seconds >= 60 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, r in
                            Capsule().fill(isSelected ? Palette.accent : Palette.accent.opacity(0.55))
                                .frame(width: max(3, geo.size.width * (r.upperBound - r.lowerBound)))
                                .offset(x: geo.size.width * r.lowerBound)
                        }
                    }
                }
                .frame(height: 6)
                .padding(.bottom, 10)
            }
            .padding(.top, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(Radius.card).fill(isSelected ? Palette.raised : (hovering && !isFuture ? Palette.card.opacity(1) : Palette.card))
                if hovering && !isSelected && !isFuture { RoundedRectangle(Radius.card).fill(Palette.hover.opacity(0.6)) }
            }
            .overlay {
                if isSelected { RoundedRectangle(Radius.card).strokeBorder(Palette.accentFocus, lineWidth: 1.5) }
                else if isFuture { RoundedRectangle(Radius.card).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3])) }
            }
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 4, y: 2)
            .contentShape(RoundedRectangle(Radius.card))
            .opacity(isFuture ? 0.6 : 1)
            .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .onHover { hovering = $0 }
        .accessibilityLabel(Fmt.dayLong(day, ko: s.ko))
    }
}

// MARK: - The day: header and timetable

private struct DayColumn: View {
    let day: Date
    let today: Date
    let now: Date
    let data: (blocks: [WorkBlock], pauses: [DayRow])
    let seconds: TimeInterval
    let focusTask: String?
    @Binding var cardBlock: UUID?
    let library: LibraryStore
    let ledger: LedgerStore
    let s: Strings
    let onDeleted: ([PlayEntry], String) -> Void

    private let timelineHeight: CGFloat = 297

    var body: some View {
        let isToday = Calendar.current.isDate(day, inSameDayAs: today)
        let longest = data.blocks.map(\.seconds).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.dayTitle(day, today: isToday)).font(AppFont.body).foregroundStyle(.secondary).lineLimit(1)
                    Text(Fmt.duration(seconds, ko: s.ko)).font(AppFont.bigNumber).monospacedDigit()
                }
                Spacer(minLength: 8)
                if longest >= 60 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(s.longestStretch).font(AppFont.caption).foregroundStyle(.secondary)
                        Text(Fmt.duration(longest, ko: s.ko)).font(AppFont.bodyStrong).monospacedDigit()
                    }
                    .padding(.bottom, 3)
                }
            }
            .frame(height: 44)
            timeline(isToday: isToday)
                .frame(height: timelineHeight)
        }
    }

    /// The hours shown: from an hour before the first stretch to an hour after the last (or now), at least 9.
    private func window(isToday: Bool) -> (start: Double, end: Double) {
        let midnight = Calendar.current.startOfDay(for: day)
        var times = data.blocks.flatMap { [$0.start, $0.end] } + data.pauses.flatMap { [$0.start, $0.end] }
        if isToday { times.append(now) }
        guard let first = times.min(), let last = times.max() else { return (9, 18) }
        var a = floor(first.timeIntervalSince(midnight) / 3600) - 1
        var b = ceil(last.timeIntervalSince(midnight) / 3600) + 1
        if b - a < 9 {
            let extra = 9 - (b - a)
            a = max(0, a - floor(extra / 2))
            b = a + 9
        }
        a = max(0, a)
        return (a, max(a + 9, b))
    }

    @ViewBuilder private func timeline(isToday: Bool) -> some View {
        let w = window(isToday: isToday)
        let midnight = Calendar.current.startOfDay(for: day)
        let inset: CGFloat = 7   // the first and last hour labels sit half above and below their lines
        let perHour = (timelineHeight - inset * 2) / CGFloat(w.end - w.start)
        let y: (Date) -> CGFloat = { inset + CGFloat($0.timeIntervalSince(midnight) / 3600 - w.start) * perHour }
        let visible = data.blocks.filter { $0.seconds >= 60 }
        let tops = (data.pauses.map { y($0.start) } + visible.map { y($0.start) }).sorted()
        // How far a short block may grow to fit its name before it would cover what comes next.
        let room: (CGFloat) -> CGFloat = { top in (tops.first { $0 > top + 0.5 } ?? .greatestFiniteMagnitude) - top }
        if data.blocks.isEmpty && data.pauses.isEmpty {
            Text(day > today ? s.futureDay : s.emptyDay)
                .font(AppFont.body).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Int(w.start)...Int(w.end), id: \.self) { hour in
                    let top = inset + CGFloat(Double(hour) - w.start) * perHour
                    Text(Fmt.pad(hour % 24)).font(AppFont.micro).foregroundStyle(.tertiary).monospacedDigit()
                        .frame(width: 24, alignment: .leading)
                        .offset(y: top - 6)
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                        .padding(.leading, 30)
                        .offset(y: top)
                }
                ForEach(data.pauses) { pause in
                    let top = y(pause.start), natural = y(pause.end) - top
                    let label = s.pauseLabel(call: pause.kind == .call, Fmt.duration(pause.seconds, ko: s.ko))
                    // Too short for words: a thin hatched strip, and the words under the pointer.
                    PauseBlock(text: natural >= 14 ? label : nil)
                        .frame(height: max(4, natural) - 2)
                        .padding(.leading, 36)
                        .offset(y: top + 1)
                        .help(label)
                }
                ForEach(visible) { block in
                    let top = y(block.start), height = max(y(block.end) - top, min(20, room(top)))
                    BlockView(block: block, height: max(3, height - 2), title: title(block), s: s,
                              dimmed: focusTask != nil && focusTask != block.intention,
                              marked: cardBlock == block.id) {
                        cardBlock = block.id
                    }
                    .popover(isPresented: Binding(get: { cardBlock == block.id }, set: { if !$0 { cardBlock = nil } }),
                             arrowEdge: .trailing) {
                        BlockCard(block: block, title: title(block), recent: ledger.recentIntentions(), library: library, s: s,
                                  onRename: { text in
                                      ledger.renamePlays(block.playIDs, to: text)
                                      cardBlock = nil
                                  },
                                  onDelete: {
                                      let removed = ledger.deletePlays(block.playIDs)
                                      cardBlock = nil
                                      onDeleted(removed, s.deletedBlock(Fmt.timeOfDay(block.start) + " – " + Fmt.timeOfDay(block.end)))
                                  },
                                  onClose: { cardBlock = nil })
                    }
                    // Padding, not offset: the card's arrow follows the block's real place.
                    .padding(.leading, 36)
                    .padding(.top, top + 1)
                }
                if isToday {
                    let top = y(now)
                    Rectangle().fill(Color.primary).frame(height: 2)
                        .padding(.leading, 30)
                        .offset(y: top - 1)
                    Text(Fmt.timeOfDay(now))
                        .font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 4).frame(height: 16)
                        .background(Capsule().fill(Color.primary))
                        .offset(y: top - 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    private func title(_ block: WorkBlock) -> String { block.intention.isEmpty ? s.noTask : block.intention }
}

/// A stretch: teal when it has a task, pale teal when it doesn't. Two lines when tall enough.
private struct BlockView: View {
    let block: WorkBlock
    let height: CGFloat
    let title: String
    let s: Strings
    let dimmed: Bool
    let marked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let named = !block.intention.isEmpty
        let twoLine = height >= 36
        let range = Fmt.timeOfDay(block.start) + " – " + Fmt.timeOfDay(block.end) + " · " + Fmt.duration(block.seconds, ko: s.ko)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                if height >= 13 {
                    Text(twoLine ? title : title + " · " + Fmt.duration(block.seconds, ko: s.ko))
                        .font(AppFont.bodyStrong).lineLimit(1)
                }
                if twoLine {
                    Text(range).font(AppFont.caption).monospacedDigit().opacity(0.85).lineLimit(1)
                }
            }
            .foregroundStyle(named ? Color.white : Palette.accentText)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: height)
            .background {
                RoundedRectangle(Radius.small).fill(named ? Palette.accent : Palette.accent.opacity(0.22))
                if hovering { RoundedRectangle(Radius.small).fill(Color.black.opacity(0.08)) }
            }
            .overlay { if marked { RoundedRectangle(Radius.small).strokeBorder(Color.primary, lineWidth: 2) } }
            .contentShape(RoundedRectangle(Radius.small))
            .opacity(dimmed ? 0.3 : 1)
            .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(range)
        .accessibilityLabel(title + ", " + range)
    }
}

/// Stepping away or a call: hatched, never counted.
private struct PauseBlock: View {
    let text: String?
    var body: some View {
        Text(text ?? "")
            .font(AppFont.micro).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(4).fill(Palette.track.opacity(0.5))
                Hatching().stroke(Palette.track, lineWidth: 2).clipShape(RoundedRectangle(4))
            }
    }
}

private struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        return path
    }
}

/// Clicking a block: its time, a name (pick a recent task or type one), its songs, Delete.
private struct BlockCard: View {
    let block: WorkBlock
    let title: String
    let recent: [String]
    let library: LibraryStore
    let s: Strings
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(Fmt.timeOfDay(block.start) + " – " + Fmt.timeOfDay(block.end) + " · " + Fmt.duration(block.seconds, ko: s.ko))
                .font(AppFont.caption).foregroundStyle(.secondary).monospacedDigit()
            if block.live {
                Text(title).font(AppFont.labelStrong)
                Text(s.recordingNow).font(AppFont.caption).foregroundStyle(.secondary)
            } else {
                TextField(s.whatWasIt, text: $draft)
                    .textFieldStyle(.roundedBorder).font(AppFont.label)
                    .focused($focused)
                    .onSubmit { onRename(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let picks = recent.filter { $0 != block.intention }.prefix(4)
                if !picks.isEmpty {
                    Text(s.recentTasks).font(AppFont.caption).foregroundStyle(.secondary)
                    FlowChips(items: Array(picks)) { onRename($0) }
                }
            }
            if !songNames.isEmpty {
                Text("♪ " + songNames).font(AppFont.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            if !block.live {
                Hairline()
                HStack {
                    Button(s.deleteWord, action: onDelete)
                        .buttonStyle(.plain).font(AppFont.bodyStrong).foregroundStyle(Color(red: 0.75, green: 0.22, blue: 0.31))
                        .padding(.horizontal, 6).frame(height: 24).hoverFill(RoundedRectangle(Radius.small))
                        .padding(.leading, -6)
                    Spacer()
                    Button(s.done) { onRename(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .buttonStyle(.plain).font(AppFont.bodyStrong).foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 6).frame(height: 24).hoverFill(RoundedRectangle(Radius.small))
                        .padding(.trailing, -6)
                }
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear {
            draft = block.intention
            focused = !block.live
        }
    }

    private var songNames: String {
        block.songs.sorted { $0.seconds > $1.seconds }.compactMap { library.track($0.id)?.title }.prefix(4).joined(separator: " · ")
    }
}

/// Recent tasks as tappable chips that wrap to a second line.
private struct FlowChips: View {
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        Button { onPick(item) } label: {
                            Text(item).font(AppFont.body).lineLimit(1)
                                .foregroundStyle(Palette.accentText)
                                .padding(.horizontal, 9).frame(height: 24)
                                .background(Capsule().fill(Palette.accentWash))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Two chips a row keeps them readable in the 270pt card.
    private var rows: [[String]] { stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) } }
}

// MARK: - The day: by task and music

private struct DaySummary: View {
    let data: (blocks: [WorkBlock], pauses: [DayRow])
    let library: LibraryStore
    @ObservedObject var settings: AppSettings
    let s: Strings
    @Binding var focusTask: String?
    @Binding var showDayStart: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tasks.isEmpty {
                Text(s.byTask).font(AppFont.bodyStrong).foregroundStyle(.secondary).padding(.bottom, 4)
                let longest = tasks.first?.seconds ?? 1
                ForEach(tasks, id: \.name) { task in
                    TaskRow(name: task.name.isEmpty ? s.noTask : task.name, seconds: task.seconds, fraction: task.seconds / max(1, longest),
                            named: !task.name.isEmpty, marked: focusTask == task.name, ko: s.ko) {
                        focusTask = focusTask == task.name ? nil : task.name
                    }
                }
                Text(s.music).font(AppFont.bodyStrong).foregroundStyle(.secondary).padding(.top, 16).padding(.bottom, 8)
                GenreBar(seconds: genres, ko: s.ko)
                songsRow.padding(.top, 12)
            }
            Spacer(minLength: 0)
            Button { showDayStart.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11))
                    Text(s.dayStartsShort(settings.dayStartHour) + " ·").foregroundStyle(.secondary)
                    Text(s.change).foregroundStyle(Palette.accentText).fontWeight(.semibold)
                }
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 26)
                .hoverFill(RoundedRectangle(Radius.control))
            }
            .buttonStyle(.plain)
            .padding(.leading, -8)
            .popover(isPresented: $showDayStart, arrowEdge: .top) { DayStartCard(settings: settings, s: s) }
        }
    }

    private var tasks: [(name: String, seconds: TimeInterval)] {
        var sums: [String: TimeInterval] = [:]
        for b in data.blocks { sums[b.intention, default: 0] += b.seconds }
        return sums.map { ($0.key, $0.value) }.sorted { ($0.name.isEmpty ? 1 : 0, -$0.seconds) < ($1.name.isEmpty ? 1 : 0, -$1.seconds) }
    }

    private var genres: [String: TimeInterval] {
        var sums: [String: TimeInterval] = [:]
        for b in data.blocks { for (g, v) in b.genreSeconds { sums[g, default: 0] += v } }
        return sums
    }

    private var songsRow: some View {
        var sums: [String: TimeInterval] = [:]
        for b in data.blocks { for song in b.songs { sums[song.id, default: 0] += song.seconds } }
        let top = sums.compactMap { pair in library.track(pair.key).map { ($0, pair.value) } }
            .sorted { ($0.1, $1.0.title) > ($1.1, $0.0.title) }.prefix(5)
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(top), id: \.0.id) { item in
                VStack(alignment: .leading, spacing: 3) {
                    CoverView(colors: item.0.colors, size: 48, image: item.0.coverURL)
                    Text(item.0.title).font(AppFont.micro).lineLimit(1)
                    Text(Fmt.hm(item.1)).font(AppFont.micro).foregroundStyle(.tertiary).monospacedDigit()
                }
                .frame(width: 64, alignment: .leading)
            }
        }
    }
}

private struct TaskRow: View {
    let name: String
    let seconds: TimeInterval
    let fraction: Double
    let named: Bool
    let marked: Bool
    let ko: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(name).font(AppFont.label).lineLimit(1)
                    .foregroundStyle(named ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 200, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track.opacity(0.7))
                        Capsule().fill(named ? Palette.accent : Palette.accent.opacity(0.35))
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 8)
                Text(Fmt.duration(seconds, ko: ko)).font(AppFont.bodyStrong).monospacedDigit()
                    .foregroundStyle(named ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 74, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background { if marked { RoundedRectangle(Radius.control).fill(Palette.accentWash) } }
            .hoverFill(RoundedRectangle(Radius.control))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
    }
}

/// Lo-fi, Electronic and Grooves as one bar, with their times underneath.
private struct GenreBar: View {
    let seconds: [String: TimeInterval]
    let ko: Bool

    private var parts: [(name: String, seconds: TimeInterval, color: Color)] {
        [(Genre.lofi, 1.0), (.electronic, 0.55), (.grooves, 0.25)].compactMap { genre, opacity in
            guard let v = seconds[genre.rawValue], v >= 30 else { return nil }
            return (genre.display, v, Palette.accent.opacity(opacity))
        }
    }

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.seconds })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.name) { part in
                        Rectangle().fill(part.color).frame(width: max(2, (geo.size.width - CGFloat(parts.count - 1) * 2) * part.seconds / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                ForEach(parts, id: \.name) { part in
                    HStack(spacing: 5) {
                        RoundedRectangle(2).fill(part.color).frame(width: 8, height: 8)
                        Text(part.name).foregroundStyle(.secondary)
                        Text(Fmt.hm(part.seconds)).fontWeight(.semibold).monospacedDigit()
                    }
                }
            }
            .font(AppFont.caption)
        }
    }
}

/// Where a day begins, and the week, right where their effect shows.
struct DayStartCard: View {
    @ObservedObject var settings: AppSettings
    let s: Strings

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(s.dayStartTitle).font(AppFont.bodyStrong)
            Segmented(options: [0, 3, 4, 5, 6, 7, 8].map { ($0, s.hourShort($0)) }, selection: settings.dayStartHour,
                      fill: true, hPadding: 4) { settings.dayStartHour = $0 }
            DayBoundary(hour: settings.dayStartHour, height: 10)
            Text(s.dayStartWhy(settings.dayStartHour)).font(AppFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Hairline().padding(.top, 2)
            HStack {
                Text(s.weekStartsOn).font(AppFont.body)
                Spacer()
                Segmented(options: [(WeekStart.monday, s.weekOptions[0]), (.sunday, s.weekOptions[1])], selection: settings.weekStart) {
                    settings.weekStart = $0
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// A day as a bar from midnight: before the start hour hatched (it counts toward the day before), a mark at the start.
struct DayBoundary: View {
    let hour: Int
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * CGFloat(hour) / 24
            ZStack(alignment: .leading) {
                RoundedRectangle(4).fill(Palette.accent.opacity(0.22))
                Hatching().stroke(Palette.track, lineWidth: 2).frame(width: x).clipped()
                Rectangle().fill(Palette.accentText).frame(width: 2).offset(x: max(0, x - 1))
            }
            .clipShape(RoundedRectangle(4))
        }
        .frame(height: height)
    }
}

// MARK: - Month

private struct MonthCalendar: View {
    let month: Date
    let today: Date
    let weekStart: WeekStart
    let s: Strings
    let value: (Date) -> TimeInterval
    let onPick: (Date) -> Void

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let days = monthDays
        let lead = (cal.component(.weekday, from: month) + (weekStart == .monday ? 5 : 6)) % 7
        let cells: [Date?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(s.weekdaySymbols(weekStart: weekStart), id: \.self) { name in
                    Text(name).font(AppFont.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(cells.indices, id: \.self) { i in
                    if let d = cells[i] {
                        MonthCell(number: cal.component(.day, from: d), seconds: d > today ? 0 : value(d),
                                  isToday: cal.isDate(d, inSameDayAs: today), isFuture: d > today) { onPick(d) }
                    } else {
                        Color.clear.frame(height: MonthCell.height)
                    }
                }
            }
            HStack(spacing: 5) {
                Text(s.less)
                ForEach([0.05, 0.16, 0.32, 0.58, 0.85], id: \.self) { a in
                    RoundedRectangle(3).fill(a == 0.05 ? Palette.track.opacity(0.6) : Palette.accent.opacity(a)).frame(width: 12, height: 12)
                }
                Text(s.more)
            }
            .font(AppFont.micro).foregroundStyle(.tertiary)
            .padding(.top, 6)
        }
    }

    private var monthDays: [Date] {
        let range = cal.range(of: .day, in: .month, for: month) ?? 1..<31
        return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }
}

private struct MonthCell: View {
    static let height: CGFloat = 52
    let number: Int
    let seconds: TimeInterval
    let isToday: Bool
    let isFuture: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let minutes = seconds / 60
        let level = minutes <= 0 ? 0 : minutes < 60 ? 1 : minutes < 120 ? 2 : minutes < 180 ? 3 : 4
        let fill = level == 0 ? Palette.track.opacity(0.6) : Palette.accent.opacity([0, 0.16, 0.32, 0.58, 0.85][level])
        Button(action: action) {
            VStack(alignment: .leading) {
                Text("\(number)").font(AppFont.captionStrong)
                Spacer(minLength: 0)
                Text(seconds >= 60 ? Fmt.hm(seconds) : "").font(AppFont.micro).monospacedDigit()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .foregroundStyle(isFuture ? AnyShapeStyle(.tertiary) : AnyShapeStyle(level >= 4 ? Color.white : Color.primary))
            .background {
                RoundedRectangle(Radius.control).fill(isFuture ? Color.clear : fill)
                if hovering && !isFuture { RoundedRectangle(Radius.control).fill(Palette.hover) }
            }
            .overlay {
                if isToday || isFuture {
                    RoundedRectangle(Radius.control).strokeBorder(Color.primary.opacity(isToday ? 0.45 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .contentShape(RoundedRectangle(Radius.control))
            .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .onHover { hovering = $0 }
    }
}

private struct MonthSummary: View {
    let days: [Date]
    let monthName: String
    let ledger: LedgerStore
    @ObservedObject var settings: AppSettings
    let now: Date
    let s: Strings

    var body: some View {
        let perDay = days.map { d -> (Date, [WorkBlock]) in
            (d, ledger.blocks(in: LedgerStore.dayInterval(forLabel: d, startHour: settings.dayStartHour), now: now).blocks)
        }
        let all = perDay.flatMap(\.1)
        var taskSums: [String: TimeInterval] = [:]
        var genreSums: [String: TimeInterval] = [:]
        for b in all {
            taskSums[b.intention, default: 0] += b.seconds
            for (g, v) in b.genreSeconds { genreSums[g, default: 0] += v }
        }
        let tasks = taskSums.map { ($0.key, $0.value) }.sorted { ($0.0.isEmpty ? 1 : 0, -$0.1) < ($1.0.isEmpty ? 1 : 0, -$1.1) }.prefix(6)
        let longest = tasks.map(\.1).max() ?? 1
        let dayTotals = perDay.map { ($0.0, $0.1.reduce(0) { $0 + $1.seconds }) }
        let played = dayTotals.filter { $0.1 >= 60 }
        let best = dayTotals.max { $0.1 < $1.1 }
        let stretch = all.map(\.seconds).max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
          if all.isEmpty {
            Text(s.emptyMonth(monthName)).font(AppFont.body).foregroundStyle(.secondary).padding(.top, 2)
          } else {
            Text(s.byTaskMonth).font(AppFont.bodyStrong).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(Array(tasks), id: \.0) { item in
                let name = item.0, seconds = item.1
                HStack(spacing: 12) {
                    Text(name.isEmpty ? s.noTask : name).font(AppFont.label).lineLimit(1)
                        .foregroundStyle(name.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .frame(width: 200, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track.opacity(0.7))
                            Capsule().fill(name.isEmpty ? Palette.accent.opacity(0.35) : Palette.accent)
                                .frame(width: max(4, geo.size.width * seconds / max(1, longest)))
                        }
                    }
                    .frame(height: 8)
                    Text(Fmt.duration(seconds, ko: s.ko)).font(AppFont.bodyStrong).monospacedDigit()
                        .foregroundStyle(name.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .frame(width: 82, alignment: .trailing)
                }
                .frame(height: 30)
            }
            Text(s.musicMonth).font(AppFont.bodyStrong).foregroundStyle(.secondary).padding(.top, 16).padding(.bottom, 8)
            GenreBar(seconds: genreSums, ko: s.ko)
            HStack(spacing: 24) {
                fact(s.daysWithFocus, s.dayCount(played.count))
                fact(s.longestDay, best.map { $0.1 >= 60 ? Fmt.dayShort($0.0, ko: s.ko) + " · " + Fmt.hm($0.1) : "—" } ?? "—")
                fact(s.longestStretch, stretch >= 60 ? Fmt.duration(stretch, ko: s.ko) : "—")
            }
            .padding(.horizontal, Metrics.cardPadding).padding(.vertical, Metrics.cardTextEdge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .padding(.top, 18)
          }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(AppFont.labelStrong).monospacedDigit().lineLimit(1)
        }
    }
}
