import Foundation
import SwiftUI

// MARK: - Catalog (written by Scripts/build_library.py) and app-owned state

struct CatalogFile: Codable {
    var version: Int
    var tracks: [CatalogTrack]
}

struct CatalogFlag: Codable, Equatable {
    var code: String
    var atSeconds: Double?
    var en: String?
    var ko: String?
}

/// A line in both languages.
struct CatalogText: Codable, Equatable {
    var en: String
    var ko: String
    func text(ko: Bool) -> String { ko ? self.ko : en }
}

/// What the song is like, written from the prompt it was made with (Scripts/library-sources.json).
struct CatalogAbout: Codable, Equatable {
    /// One line under the title: Library rows and the top of the song page.
    var vibe: CatalogText?
    /// What repeats in it, for the song page's "Just a loop" row.
    var loop: CatalogText?
}

struct CatalogTrack: Codable {
    var id: String
    var title: String
    var genre: String
    var file: String
    var durationSeconds: Double?
    var gainDb: Double?
    var bpm: Double?
    var beatOffsetSeconds: Double?
    var gridVerified: Bool?
    var modulationHz: Double?
    var palette: [String]?
    var status: String?
    var flags: [CatalogFlag]?
    /// The repeatable middle (null: the track plays once), see Scripts/loop_points.py.
    var loopStartSeconds: Double? = nil
    var loopEndSeconds: Double? = nil
    var loopSeamCorrelation: Double? = nil
    var about: CatalogAbout? = nil
    /// The song's cover (generated with Suno), relative to the library folder (covers/<id>.jpg).
    var cover: String? = nil
    /// How the focus pulse locks to the music: "grid" (steady beat), "follow" (beatTimes) or
    /// "steady" (no beat to follow). Absent in older catalogs: the pulse needs gridVerified.
    var pulseMode: String? = nil
    var beatTimes: [Double]? = nil
    var pulseCyclesPerBeat: Int? = nil
    /// When build_library first added the song (ISO 8601); the playlist's "Recently added".
    var addedAt: String? = nil
}

enum TrackStatus: String, Codable { case new, inMix, removed }

struct TrackState: Codable, Equatable {
    var status: TrackStatus
    var liked = false
    var plays = 0
    var skips = 0
    var completes = 0
    var listenedSeconds: Double = 0
}

struct LibraryStateFile: Codable {
    var version = 1
    var tracks: [String: TrackState] = [:]
}

struct Track: Identifiable, Equatable {
    let id: String
    let title: String
    let genre: Genre
    let url: URL
    let duration: Double
    let gainDb: Double
    let modulationHz: Double?
    let beatOffset: Double
    /// Loop region in seconds (both set or both nil) and its seam correlation.
    let loopStart: Double?
    let loopEnd: Double?
    let loopSeamCorrelation: Double
    let palette: [String]
    let flags: [CatalogFlag]
    /// Measured tempo, nil when the catalog has none.
    var bpm: Double? = nil
    var about: CatalogAbout? = nil
    /// The cover picture in the library folder; nil draws the colour cover instead.
    var coverURL: URL? = nil
    /// The pulse follows these beats (seconds) when the tempo drifts; see EngineTrack.beatTimes.
    var beatTimes: [Double]? = nil
    var pulseCyclesPerBeat: Int = 0
    var addedAt: Date? = nil
    var state: TrackState

    var status: TrackStatus { state.status }
    var liked: Bool { state.liked }
    /// Added and not played yet: the playlist marks it New.
    var isNew: Bool { state.status == .new }

    /// The one-line description, or nil when the catalog has none.
    func vibe(ko: Bool) -> String? { about?.vibe?.text(ko: ko) }

    /// Slow songs (lo-fi runs about 90–105 BPM, the rest about 120) get the song page's "Slow and soft" row.
    var isSlow: Bool { (bpm ?? 0) > 0 && (bpm ?? 0) < 110 }

    /// 0...1, Laplace-smoothed share of full listens among decided plays. 0.5 = no evidence yet.
    var fit: Double {
        let decided = state.completes + state.skips
        return Double(state.completes + 1) / Double(decided + 2)
    }

    var colors: [Color] {
        let hexes = palette.count >= 3 ? palette : ["#2F6BFF", "#22D3EE", "#6D28D9"]
        return hexes.prefix(3).map { Color(hex: $0) }
    }

    /// Every song plays for at least 30 minutes: its steady middle repeats (FocusTrackVoice).
    static let minimumPlaySeconds: Double = 1800

    /// How long the song is in the app: the file plus whole passes of its loop region until
    /// 30 minutes are reached, as the audio engine plans it (FocusLoopPlan: 1 s seams, so the
    /// region must sit 0.5 s inside the file and span at least 2 s). Without one, the file once.
    var playLength: Double {
        guard let start = loopStart, let end = loopEnd, start.isFinite, end.isFinite,
              start >= 0.5, end + 0.5 <= duration, end - start >= 2,
              Self.minimumPlaySeconds > duration else { return duration }
        let period = end - start
        let repeats = ((Self.minimumPlaySeconds - duration) / period).rounded(.up)
        return duration + repeats * period
    }
}

// MARK: - Store

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var undoItem: (id: String, previous: TrackStatus, title: String)?

    private let paths: AppPaths
    private var state = LibraryStateFile()
    private var catalogDate: Date?
    private var watchTimer: Timer?
    private var undoTimer: Timer?

    init(paths: AppPaths) {
        self.paths = paths
        state = JSONStore.read(LibraryStateFile.self, from: paths.libraryStateURL) ?? LibraryStateFile()
        reload()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfCatalogChanged() }
        }
    }

    func reloadIfCatalogChanged() {
        let date = (try? FileManager.default.attributesOfItem(atPath: paths.catalogURL.path)[.modificationDate]) as? Date
        if date != catalogDate { reload() }
    }

    func reload() {
        catalogDate = (try? FileManager.default.attributesOfItem(atPath: paths.catalogURL.path)[.modificationDate]) as? Date
        guard let catalog = JSONStore.read(CatalogFile.self, from: paths.catalogURL) else {
            tracks = []
            return
        }
        var result: [Track] = []
        var changedState = false
        let stamp = ISO8601DateFormatter()
        for item in catalog.tracks {
            guard let genre = Genre(rawValue: item.genre) else { continue }
            let url = paths.libraryDir.appendingPathComponent(item.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var trackState = state.tracks[item.id]
            if trackState == nil {
                let initial = TrackStatus(rawValue: item.status ?? "new") ?? .new
                trackState = TrackState(status: initial == .removed ? .new : initial)
                state.tracks[item.id] = trackState
                changedState = true
            }
            let loop = Self.loop(item)
            result.append(Track(
                id: item.id, title: item.title, genre: genre, url: url,
                duration: item.durationSeconds ?? 0, gainDb: item.gainDb ?? 0,
                modulationHz: (item.pulseMode != nil || (item.gridVerified ?? false)) ? item.modulationHz : nil,
                beatOffset: item.beatOffsetSeconds ?? 0,
                loopStart: loop?.start, loopEnd: loop?.end,
                loopSeamCorrelation: loop == nil ? 0 : (item.loopSeamCorrelation ?? 0),
                palette: item.palette ?? [], flags: item.flags ?? [],
                bpm: item.bpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, about: item.about,
                coverURL: item.cover.map { paths.libraryDir.appendingPathComponent($0) }
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
                beatTimes: item.pulseMode == "follow" ? item.beatTimes : nil,
                pulseCyclesPerBeat: item.pulseMode == "follow" ? (item.pulseCyclesPerBeat ?? 0) : 0,
                addedAt: item.addedAt.flatMap { stamp.date(from: $0) },
                state: trackState!))
        }
        tracks = result
        if changedState { saveState() }
    }

    private func saveState() { JSONStore.write(state, to: paths.libraryStateURL) }

    /// Loop points that make sense for the track, else nil (it then plays once).
    static func loop(_ item: CatalogTrack) -> (start: Double, end: Double)? {
        guard let start = item.loopStartSeconds, let end = item.loopEndSeconds,
              start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        if let duration = item.durationSeconds, duration > 0, end > duration { return nil }
        if let correlation = item.loopSeamCorrelation, !correlation.isFinite { return nil }
        return (start, end)
    }

    private func update(_ id: String, _ change: (inout TrackState) -> Void) {
        guard var s = state.tracks[id] else { return }
        change(&s)
        state.tracks[id] = s
        if let index = tracks.firstIndex(where: { $0.id == id }) { tracks[index].state = s }
        saveState()
    }

    func track(_ id: String?) -> Track? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    // Playlist actions
    /// "Play again" from the Not playing list.
    func restore(_ id: String) { update(id) { $0.status = .inMix } }

    /// The first play takes the New tag off.
    func markPlayed(_ id: String) {
        guard track(id)?.status == .new else { return }
        update(id) { $0.status = .inMix }
    }

    func remove(_ id: String) {
        guard let track = track(id) else { return }
        let previous = track.status
        update(id) { $0.status = .removed }
        undoItem = (id, previous, track.title)
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.undoItem = nil }
        }
    }

    func undoRemove() {
        guard let item = undoItem else { return }
        update(item.id) { $0.status = item.previous }
        undoItem = nil
        undoTimer?.invalidate()
    }

    func toggleLike(_ id: String) { update(id) { $0.liked.toggle() } }

    /// Songs the learning plays less now: more early skips than full listens (weight under 1 in `pickNext`).
    func lessPlayed() -> [Track] {
        tracks.filter { $0.status != .removed && $0.state.skips > $0.state.completes }
    }

    /// Settings' "Clear": forget what was learned about these songs, so they come up like the rest.
    func clearLearning(_ ids: [String]) {
        for id in ids {
            update(id) { s in
                s.plays = 0
                s.skips = 0
                s.completes = 0
                s.listenedSeconds = 0
            }
        }
    }

    /// Learning signal. `skipped` means the user moved on early (under a minute).
    func recordListen(_ id: String, listened: Double, skipped: Bool, completed: Bool) {
        update(id) { s in
            s.plays += 1
            s.listenedSeconds += listened
            if skipped { s.skips += 1 } else if completed { s.completes += 1 }
        }
    }

    // Queries
    /// Everything that plays: new songs too. Only "Don't play" takes a song out.
    func mixTracks() -> [Track] { tracks.filter { $0.status != .removed } }
    func hiddenTracks() -> [Track] { tracks.filter { $0.status == .removed } }

    func playable(for choice: MusicChoice) -> [Track] {
        let mix = mixTracks()
        guard let genre = choice.genre else { return mix }
        return mix.filter { $0.genre == genre }
    }

    /// The playlist in the chosen order. Default: by genre (Lo-fi, Grooves, Electronic), catalog order inside.
    func ordered(for choice: MusicChoice, sort: PlaylistSort) -> [Track] {
        Self.sorted(playable(for: choice), by: sort, catalog: tracks)
    }

    /// The order rule on its own, so the hidden list sorts the same way.
    static func sorted(_ list: [Track], by sort: PlaylistSort, catalog: [Track]) -> [Track] {
        let index = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ($1.id, $0) })
        let genreRank = Dictionary(uniqueKeysWithValues: Genre.allCases.enumerated().map { ($1, $0) })
        func standard(_ a: Track, _ b: Track) -> Bool {
            let ga = genreRank[a.genre] ?? 0, gb = genreRank[b.genre] ?? 0
            if ga != gb { return ga < gb }
            return (index[a.id] ?? 0) < (index[b.id] ?? 0)
        }
        switch sort {
        case .standard:
            return list.sorted(by: standard)
        case .recent:
            return list.sorted { a, b in
                let da = a.addedAt ?? .distantPast, db = b.addedAt ?? .distantPast
                if da != db { return da > db }
                return (index[a.id] ?? 0) > (index[b.id] ?? 0)
            }
        case .liked:
            return list.sorted { a, b in
                if a.liked != b.liked { return a.liked }
                return standard(a, b)
            }
        case .name:
            return list.sorted { a, b in
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? standard(a, b) : order == .orderedAscending
            }
        }
    }

    /// With shuffle off: the song after `id` in the playlist's order, back to the top after the last.
    func nextInOrder(after id: String?, for choice: MusicChoice, sort: PlaylistSort) -> Track? {
        neighbor(of: id, step: 1, for: choice, sort: sort)
    }

    /// The song before `id` in the playlist's order (wraps to the last).
    func previousInOrder(before id: String?, for choice: MusicChoice, sort: PlaylistSort) -> Track? {
        neighbor(of: id, step: -1, for: choice, sort: sort)
    }

    /// A song that just left the list (Don't play, another genre) still has a place in the order:
    /// its neighbours are the songs that were around it.
    private func neighbor(of id: String?, step: Int, for choice: MusicChoice, sort: PlaylistSort) -> Track? {
        var list = ordered(for: choice, sort: sort)
        guard !list.isEmpty else { return nil }
        guard let id else { return step > 0 ? list.first : list.last }
        if !list.contains(where: { $0.id == id }) {
            guard let gone = track(id) else { return step > 0 ? list.first : list.last }
            list = Self.sorted(list + [gone], by: sort, catalog: tracks)
        }
        guard let at = list.firstIndex(where: { $0.id == id }) else { return list.first }
        let next = list[((at + step) % list.count + list.count) % list.count]
        return next.id == id ? nil : next
    }

    /// Shuffle: a weighted pick (♥ doubles the weight, learned fit scales it) among the songs not heard lately.
    /// `recent` is what played, oldest first (the song on now last). The latest half of what can play waits its
    /// turn: on Mix with 27 songs nothing comes back within 13 songs, about six and a half hours.
    func pickNext(for choice: MusicChoice, avoiding recent: [String], learn: Bool) -> Track? {
        let pool = playable(for: choice)
        guard !pool.isEmpty else { return nil }
        let canPlay = Set(pool.map(\.id))
        // Newest first, each song once, only songs that can play now.
        var lately: [String] = []
        for id in recent.reversed() where canPlay.contains(id) && !lately.contains(id) { lately.append(id) }
        let waiting = Set(lately.prefix(max(1, pool.count / 2)))
        var candidates = pool.filter { !waiting.contains($0.id) }
        if candidates.isEmpty { candidates = pool.filter { $0.id != lately.first } }
        if candidates.isEmpty { candidates = pool }
        let weights = candidates.map { t -> Double in
            (t.liked ? 2.0 : 1.0) * (learn ? (0.3 + 1.4 * t.fit) : 1.0)
        }
        let total = weights.reduce(0, +)
        var roll = Double.random(in: 0..<max(total, 0.0001))
        for (index, w) in weights.enumerated() {
            roll -= w
            if roll <= 0 { return candidates[index] }
        }
        return candidates.last
    }
}
