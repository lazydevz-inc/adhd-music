import Foundation

/// A stretch of time when music was playing and counted as work.
struct PlayEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var intention: String
    var genre: String?
    /// Library ids of the songs that played, in order (missing in entries from before 11/23).
    var tracks: [String]? = nil
    /// When each song in `tracks` came on, in the same order (entries from 11/24 on).
    var trackStarts: [Date]? = nil
}

/// Time the app paused by itself (screen locked, call). Shown in History, never counted.
struct GapEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var reason: String   // "away" | "call"
}

struct OpenPlay: Codable, Equatable {
    var start: Date
    var checkpoint: Date
    var intention: String
    var genre: String?
    var tracks: [String]? = nil
    /// When the last song in `tracks` came on; one replaced within seconds is dropped.
    var trackSince: Date? = nil
    var trackStarts: [Date]? = nil

    func closed(at end: Date) -> PlayEntry {
        PlayEntry(start: start, end: end, intention: intention, genre: genre, tracks: tracks, trackStarts: trackStarts)
    }
}

struct OpenGap: Codable, Equatable {
    var start: Date
    var checkpoint: Date
    var reason: String
}

struct LedgerFile: Codable {
    var version = 2
    var plays: [PlayEntry] = []
    var gaps: [GapEntry] = []
    var openPlay: OpenPlay?
    var openGap: OpenGap?
}

/// Row shown in History (a play, or an automatic pause).
struct DayRow: Identifiable, Equatable {
    enum Kind: Equatable { case play, away, call }
    let id: UUID
    let kind: Kind
    let start: Date
    let end: Date
    let live: Bool
    let intention: String
    let genre: String?
    /// Library ids of the songs played in this stretch (empty for pauses and older records).
    var tracks: [String] = []
    var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// One stretch of one task in History, made of one or more plays (see `LedgerStore.blocks`).
struct WorkBlock: Identifiable, Equatable {
    struct SongTime: Equatable { let id: String; var seconds: TimeInterval }
    let id: UUID
    var playIDs: [UUID]
    var start: Date
    var end: Date
    /// Time played (short joins between its plays not counted).
    var seconds: TimeInterval
    var intention: String
    var live: Bool
    var songs: [SongTime] = []
    var genreSeconds: [String: TimeInterval] = [:]

    mutating func add(songs more: [(id: String, seconds: TimeInterval)], genre: String?, seconds: TimeInterval) {
        for song in more {
            if let i = songs.firstIndex(where: { $0.id == song.id }) { songs[i].seconds += song.seconds }
            else { songs.append(SongTime(id: song.id, seconds: song.seconds)) }
        }
        if let genre { genreSeconds[genre, default: 0] += seconds }
    }
}

@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var file = LedgerFile()
    private let url: URL

    init(url: URL) {
        self.url = url
        file = JSONStore.read(LedgerFile.self, from: url) ?? LedgerFile()
        recoverOpenEntries()
    }

    /// A crash or force-quit leaves an open entry behind: close it at its last checkpoint.
    private func recoverOpenEntries() {
        var changed = false
        if let open = file.openPlay {
            if open.checkpoint.timeIntervalSince(open.start) >= 1 {
                file.plays.append(open.closed(at: open.checkpoint))
            }
            file.openPlay = nil
            changed = true
        }
        if let gap = file.openGap {
            if gap.checkpoint.timeIntervalSince(gap.start) >= 1 {
                file.gaps.append(GapEntry(start: gap.start, end: gap.checkpoint, reason: gap.reason))
            }
            file.openGap = nil
            changed = true
        }
        if changed { save() }
    }

    func save() { JSONStore.write(file, to: url) }

    var isRecording: Bool { file.openPlay != nil }

    func beginPlay(at date: Date = Date(), intention: String, genre: String?, track: String? = nil) {
        guard file.openPlay == nil else { return }
        file.openPlay = OpenPlay(start: date, checkpoint: date, intention: intention, genre: genre,
                                 tracks: track.map { [$0] }, trackSince: track == nil ? nil : date,
                                 trackStarts: track == nil ? nil : [date])
        save()
    }

    func endPlay(at date: Date = Date()) {
        guard let open = file.openPlay else { return }
        if date.timeIntervalSince(open.start) >= 1 {
            file.plays.append(open.closed(at: date))
        }
        file.openPlay = nil
        save()
    }

    /// Ends the running entry and starts a new one with a different intention or genre.
    /// The song playing carries over into the new entry.
    func split(at date: Date = Date(), intention: String, genre: String?) {
        guard let open = file.openPlay else { return }
        if open.intention == intention && open.genre == genre { return }
        if date.timeIntervalSince(open.start) < 20 {
            // Barely started: relabel instead of leaving a sliver.
            file.openPlay?.intention = intention
            file.openPlay?.genre = genre
            save()
            return
        }
        endPlay(at: date)
        beginPlay(at: date, intention: intention, genre: genre, track: open.tracks?.last)
    }

    /// The songs heard lately, oldest first (at most `limit`), so shuffling carries on across restarts.
    func recentTracks(limit: Int = 60) -> [String] {
        var ids: [String] = []
        for play in file.plays.sorted(by: { $0.start < $1.start }) { ids += play.tracks ?? [] }
        ids += file.openPlay?.tracks ?? []
        return Array(ids.suffix(limit))
    }

    /// Seconds a song has to play before it stays in the entry's song list when the next one comes on.
    static let trackKeepSeconds: TimeInterval = 20

    /// A song came on while recording: add it to the running entry. A song that played only a few
    /// seconds before this one (skipped right away) is replaced rather than listed.
    func noteTrack(_ id: String, at date: Date = Date()) {
        guard var open = file.openPlay else { return }
        var tracks = open.tracks ?? []
        if tracks.last == id { return }
        // Start times run alongside the songs; an entry from before they were kept goes on without them.
        var starts: [Date]? = open.trackStarts.flatMap { $0.count == tracks.count ? $0 : nil }
        var slotStart = date
        if !tracks.isEmpty, let since = open.trackSince, date.timeIntervalSince(since) < Self.trackKeepSeconds {
            // Skipped within seconds: the next song takes its place, from when that place began.
            tracks.removeLast()
            if let last = starts?.popLast() { slotStart = last }
        }
        if tracks.last != id {
            tracks.append(id)
            starts?.append(slotStart)
        }
        open.tracks = tracks
        open.trackStarts = starts
        open.trackSince = date
        file.openPlay = open
        save()
    }

    func beginGap(reason: String, at date: Date = Date()) {
        guard file.openGap == nil else { return }
        file.openGap = OpenGap(start: date, checkpoint: date, reason: reason)
        save()
    }

    func endGap(at date: Date = Date()) {
        guard let gap = file.openGap else { return }
        if date.timeIntervalSince(gap.start) >= 30 {
            file.gaps.append(GapEntry(start: gap.start, end: date, reason: gap.reason))
        }
        file.openGap = nil
        save()
    }

    func checkpoint(at date: Date = Date()) {
        var changed = false
        if file.openPlay != nil { file.openPlay?.checkpoint = date; changed = true }
        if file.openGap != nil { file.openGap?.checkpoint = date; changed = true }
        if changed { save() }
    }

    func updateIntention(_ id: UUID, to text: String) {
        guard let index = file.plays.firstIndex(where: { $0.id == id }) else { return }
        file.plays[index].intention = text
        save()
    }

    func deletePlay(_ id: UUID) {
        file.plays.removeAll { $0.id == id }
        save()
    }

    /// A block in History is one or more plays: renaming it renames them all.
    func renamePlays(_ ids: [UUID], to text: String) {
        let set = Set(ids)
        for i in file.plays.indices where set.contains(file.plays[i].id) { file.plays[i].intention = text }
        save()
    }

    /// Removes the plays and hands them back, so History can offer Undo.
    @discardableResult
    func deletePlays(_ ids: [UUID]) -> [PlayEntry] {
        let set = Set(ids)
        let removed = file.plays.filter { set.contains($0.id) }
        file.plays.removeAll { set.contains($0.id) }
        save()
        return removed
    }

    func restorePlays(_ entries: [PlayEntry]) {
        let present = Set(file.plays.map(\.id))
        file.plays.append(contentsOf: entries.filter { !present.contains($0.id) })
        file.plays.sort { $0.start < $1.start }
        save()
    }

    /// Tasks written lately, newest first, for picking a name instead of typing it.
    func recentIntentions(limit: Int = 4) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let named = file.plays.sorted { $0.end > $1.end }.map { $0.intention.trimmingCharacters(in: .whitespacesAndNewlines) }
        for text in [file.openPlay?.intention.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""] + named
        where !text.isEmpty && !seen.contains(text) {
            seen.insert(text)
            out.append(text)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Day math

    static func dayInterval(containing date: Date, startHour: Int, calendar: Calendar = .current) -> DateInterval {
        var start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date) ?? date
        if start > date { start = calendar.date(byAdding: .day, value: -1, to: start) ?? start }
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    /// Interval for a calendar day label (e.g. Nov 20 means Nov 20 06:00 → Nov 21 06:00).
    static func dayInterval(forLabel day: Date, startHour: Int, calendar: Calendar = .current) -> DateInterval {
        let midnight = calendar.startOfDay(for: day)
        let start = calendar.date(byAdding: .hour, value: startHour, to: midnight) ?? midnight
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }

    /// The calendar day a moment belongs to, given the day start hour.
    static func dayLabel(for date: Date, startHour: Int, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: dayInterval(containing: date, startHour: startHour, calendar: calendar).start)
    }

    private func clipped(_ start: Date, _ end: Date, to interval: DateInterval) -> TimeInterval {
        let s = max(start, interval.start), e = min(end, interval.end)
        return max(0, e.timeIntervalSince(s))
    }

    func seconds(in interval: DateInterval, now: Date = Date()) -> TimeInterval {
        var total = file.plays.reduce(0) { $0 + clipped($1.start, $1.end, to: interval) }
        if let open = file.openPlay { total += clipped(open.start, now, to: interval) }
        return total
    }

    func rows(in interval: DateInterval, now: Date = Date()) -> [DayRow] {
        var rows: [DayRow] = []
        for p in file.plays where p.end > interval.start && p.start < interval.end {
            rows.append(DayRow(id: p.id, kind: .play, start: max(p.start, interval.start), end: min(p.end, interval.end),
                               live: false, intention: p.intention, genre: p.genre, tracks: p.tracks ?? []))
        }
        for g in file.gaps where g.end > interval.start && g.start < interval.end {
            rows.append(DayRow(id: g.id, kind: g.reason == "call" ? .call : .away, start: max(g.start, interval.start),
                               end: min(g.end, interval.end), live: false, intention: "", genre: nil))
        }
        if let open = file.openPlay, now > interval.start, open.start < interval.end {
            rows.append(DayRow(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, kind: .play,
                               start: max(open.start, interval.start), end: min(now, interval.end), live: true,
                               intention: open.intention, genre: open.genre, tracks: open.tracks ?? []))
        }
        return rows.sorted { $0.start < $1.start }
    }

    /// Seconds each song played in an entry: from the start times when kept, else shared evenly.
    static func songSeconds(tracks: [String], starts: [Date]?, start: Date, end: Date) -> [(id: String, seconds: TimeInterval)] {
        guard !tracks.isEmpty, end > start else { return [] }
        if let starts, starts.count == tracks.count {
            return tracks.indices.map { i in
                let from = max(starts[i], start)
                let to = min(i + 1 < starts.count ? starts[i + 1] : end, end)
                return (tracks[i], max(0, to.timeIntervalSince(from)))
            }
        }
        let each = end.timeIntervalSince(start) / Double(tracks.count)
        return tracks.map { ($0, each) }
    }

    /// The stretches History draws for a day: plays with the same task that follow each other within
    /// `joinGap` seconds become one block (a song or genre change doesn't split it; a pause for a call
    /// or stepping away does). Pauses come back as their own rows.
    func blocks(in interval: DateInterval, now: Date = Date(), joinGap: TimeInterval = 300) -> (blocks: [WorkBlock], pauses: [DayRow]) {
        let liveID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        struct Piece { let id: UUID; let start: Date; let end: Date; let intention: String; let genre: String?; let songs: [(id: String, seconds: TimeInterval)]; let live: Bool }
        var pieces: [Piece] = []
        for p in file.plays where p.end > interval.start && p.start < interval.end {
            let s = max(p.start, interval.start), e = min(p.end, interval.end)
            pieces.append(Piece(id: p.id, start: s, end: e, intention: p.intention.trimmingCharacters(in: .whitespacesAndNewlines),
                                genre: p.genre, songs: Self.songSeconds(tracks: p.tracks ?? [], starts: p.trackStarts, start: s, end: e), live: false))
        }
        if let open = file.openPlay, now > interval.start, open.start < interval.end {
            let s = max(open.start, interval.start), e = min(now, interval.end)
            pieces.append(Piece(id: liveID, start: s, end: e, intention: open.intention.trimmingCharacters(in: .whitespacesAndNewlines),
                                genre: open.genre, songs: Self.songSeconds(tracks: open.tracks ?? [], starts: open.trackStarts, start: s, end: e), live: true))
        }
        pieces.sort { $0.start < $1.start }
        let pauses = file.gaps.filter { $0.end > interval.start && $0.start < interval.end }.map { g in
            DayRow(id: g.id, kind: g.reason == "call" ? .call : .away, start: max(g.start, interval.start),
                   end: min(g.end, interval.end), live: false, intention: "", genre: nil)
        }.sorted { $0.start < $1.start }
        func pauseBetween(_ a: Date, _ b: Date) -> Bool { pauses.contains { $0.end > a && $0.start < b } }
        var blocks: [WorkBlock] = []
        for piece in pieces {
            let seconds = piece.end.timeIntervalSince(piece.start)
            if var last = blocks.last, last.intention == piece.intention,
               piece.start.timeIntervalSince(last.end) <= joinGap, !pauseBetween(last.end, piece.start) {
                last.playIDs.append(piece.id)
                last.end = max(last.end, piece.end)
                last.seconds += seconds
                last.live = last.live || piece.live
                last.add(songs: piece.songs, genre: piece.genre, seconds: seconds)
                blocks[blocks.count - 1] = last
            } else {
                var block = WorkBlock(id: piece.id, playIDs: [piece.id], start: piece.start, end: piece.end, seconds: seconds,
                                      intention: piece.intention, live: piece.live)
                block.add(songs: piece.songs, genre: piece.genre, seconds: seconds)
                blocks.append(block)
            }
        }
        return (blocks, pauses)
    }

    func lastPlayEnd(before date: Date) -> Date? {
        file.plays.filter { $0.end <= date }.map(\.end).max()
    }

    // MARK: Demo data for development screenshots only

    /// `given`: song ids per genre from the library (the first two of each are used); a genre with no
    /// songs gets stand-in ids.
    func seedDemo(today: Date = Date(), startHour: Int, songs given: [String: [String]] = [:]) {
        let cal = Calendar.current
        let minutes = [0, 142, 188, 160, 205, 121, 35, 0, 176, 150, 198, 167, 140, 48, 20, 185, 161, 172, 134]
        let todayLabel = LedgerStore.dayLabel(for: today, startHour: startHour)
        let dayOfMonth = cal.component(.day, from: todayLabel)
        file = LedgerFile()
        var songs: [String: [String]] = [:]
        for genre in Genre.allCases.map(\.rawValue) {
            let ids = Array((given[genre] ?? []).prefix(2))
            songs[genre] = ids.isEmpty ? ["demo-\(genre)-a", "demo-\(genre)-b"] : ids
        }
        let electronic = songs["electronic"] ?? []
        let lofi = Array((songs["lofi"] ?? []).prefix(1))
        for (offset, total) in minutes.enumerated() where total > 0 {
            let dayNumber = offset + 1
            var parts0 = cal.dateComponents([.year, .month], from: todayLabel)
            parts0.day = dayNumber
            guard dayNumber < dayOfMonth, let label = cal.date(from: parts0) else { continue }
            let midnight = cal.startOfDay(for: label)
            let parts = total > 150 ? [0.45, 0.35, 0.2] : total > 70 ? [0.6, 0.4] : [1.0]
            let starts = [9 * 60 + (dayNumber % 4) * 10, 13 * 60 + 20 + (dayNumber % 3) * 15, 16 * 60 + (dayNumber % 5) * 6]
            var used = 0
            for (i, share) in parts.enumerated() {
                let d = i == parts.count - 1 ? total - used : Int((Double(total) * share).rounded())
                used += d
                let start = midnight.addingTimeInterval(TimeInterval(starts[i] * 60))
                let genre = ["lofi", "grooves", "electronic"][(dayNumber + i) % 3]
                file.plays.append(PlayEntry(start: start, end: start.addingTimeInterval(TimeInterval(d * 60)),
                                            intention: "", genre: genre, tracks: songs[genre]))
            }
        }
        let midnight = cal.startOfDay(for: todayLabel)
        func at(_ h: Int, _ m: Int) -> Date { midnight.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        if today > at(11, 0) {
            file.plays.append(PlayEntry(start: at(9, 12), end: at(10, 0), intention: "Refactor the auth module", genre: "electronic",
                                        tracks: electronic))
            file.gaps.append(GapEntry(start: at(10, 0), end: at(10, 12), reason: "away"))
            file.plays.append(PlayEntry(start: at(10, 12), end: at(11, 0), intention: "Refactor the auth module", genre: "electronic",
                                        tracks: electronic.reversed()))
        }
        if today > at(14, 8) {
            file.plays.append(PlayEntry(start: at(13, 30), end: at(14, 8), intention: "", genre: "lofi", tracks: lofi))
        }
        save()
    }
}
