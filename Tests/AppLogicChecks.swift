// Logic checks for the ledger (day boundaries, recovery) and library selection.
// Build & run: Scripts/check-app-logic.sh
import Foundation

@MainActor
func runChecks() -> Int32 {
    var failures = 0
    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        print((condition ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
        if !condition { failures += 1 }
    }
    let cal = Calendar.current
    func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("focus-logic-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Day boundaries at 6 AM
    let early = LedgerStore.dayInterval(containing: date(20, 5, 30), startHour: 6)
    check("5:30 AM belongs to the previous day", early.start == date(19, 6) && early.end == date(20, 6))
    let morning = LedgerStore.dayInterval(containing: date(20, 6, 0), startHour: 6)
    check("6:00 AM starts a new day", morning.start == date(20, 6))
    check("day label for 2 AM is yesterday", cal.isDate(LedgerStore.dayLabel(for: date(21, 2), startHour: 6), inSameDayAs: date(20, 12)))
    let midnightDay = LedgerStore.dayInterval(containing: date(20, 0, 30), startHour: 0)
    check("midnight start works", midnightDay.start == date(20, 0))

    // Totals clip at the boundary
    let ledger = LedgerStore(url: tmp.appendingPathComponent("records.json"))
    ledger.beginPlay(at: date(20, 23, 0), intention: "late", genre: "lofi")
    ledger.endPlay(at: date(21, 7, 0))
    let day20 = LedgerStore.dayInterval(forLabel: date(20, 12), startHour: 6)
    let day21 = LedgerStore.dayInterval(forLabel: date(21, 12), startHour: 6)
    check("late session counts 7h to Nov 20", abs(ledger.seconds(in: day20, now: date(21, 8)) - 7 * 3600) < 1)
    check("and 1h to Nov 21", abs(ledger.seconds(in: day21, now: date(21, 8)) - 3600) < 1)

    // Open entry counts live and is recovered after a crash at its checkpoint
    ledger.beginPlay(at: date(21, 9, 0), intention: "focus", genre: nil)
    check("open play counts toward today", abs(ledger.seconds(in: day21, now: date(21, 9, 30)) - (3600 + 1800)) < 1)
    ledger.checkpoint(at: date(21, 9, 20))
    let reopened = LedgerStore(url: tmp.appendingPathComponent("records.json"))
    check("crash recovery closes at checkpoint", reopened.file.openPlay == nil && reopened.file.plays.last?.end == date(21, 9, 20))

    // Intention split
    let l2 = LedgerStore(url: tmp.appendingPathComponent("r2.json"))
    l2.beginPlay(at: date(22, 9), intention: "A", genre: nil)
    l2.split(at: date(22, 10), intention: "B", genre: nil)
    l2.endPlay(at: date(22, 11))
    check("split makes two rows", l2.file.plays.count == 2 && l2.file.plays[0].intention == "A" && l2.file.plays[1].intention == "B")
    l2.beginPlay(at: date(22, 12), intention: "C", genre: nil)
    l2.split(at: date(22, 12, 0).addingTimeInterval(10), intention: "D", genre: nil)
    check("split in the first seconds relabels instead", l2.file.openPlay?.intention == "D" && l2.file.plays.count == 2)
    l2.endPlay(at: date(22, 13))

    // Songs played are kept with each entry (Day shows their names)
    let l3 = LedgerStore(url: tmp.appendingPathComponent("r3.json"))
    l3.beginPlay(at: date(23, 9), intention: "A", genre: "electronic", track: "s1")
    l3.noteTrack("s1", at: date(23, 9, 1))
    l3.noteTrack("s2", at: date(23, 9, 30))
    l3.noteTrack("s3", at: date(23, 9, 30).addingTimeInterval(5))
    check("a song skipped within seconds is replaced, repeats are not listed twice", l3.file.openPlay?.tracks == ["s1", "s3"],
          "\(l3.file.openPlay?.tracks ?? [])")
    l3.split(at: date(23, 10), intention: "B", genre: "electronic")
    check("a new task keeps the song that is playing", l3.file.plays.last?.tracks == ["s1", "s3"] && l3.file.openPlay?.tracks == ["s3"])
    l3.noteTrack("s4", at: date(23, 10, 40))
    l3.endPlay(at: date(23, 11))
    let day23 = LedgerStore.dayInterval(forLabel: date(23, 12), startHour: 6)
    check("Day rows carry the song ids", l3.rows(in: day23, now: date(23, 12)).map(\.tracks) == [["s1", "s3"], ["s3", "s4"]])
    l3.beginPlay(at: date(23, 13), intention: "", genre: nil, track: "s5")
    l3.checkpoint(at: date(23, 13, 20))
    let l3b = LedgerStore(url: tmp.appendingPathComponent("r3.json"))
    check("crash recovery keeps the songs", l3b.file.plays.last?.tracks == ["s5"])
    check("songs heard lately, oldest first, for shuffling after a restart",
          l3b.recentTracks() == ["s1", "s3", "s3", "s4", "s5"] && l3b.recentTracks(limit: 2) == ["s4", "s5"])
    // History blocks: one stretch per task, songs with their times, rename / delete / undo
    let l4 = LedgerStore(url: tmp.appendingPathComponent("r4.json"))
    l4.beginPlay(at: date(24, 9), intention: "A", genre: "lofi", track: "s1")
    l4.noteTrack("s2", at: date(24, 9, 10))
    l4.endPlay(at: date(24, 9, 30))
    l4.beginPlay(at: date(24, 9, 32), intention: "A", genre: "grooves", track: "s3")
    l4.endPlay(at: date(24, 9, 40))
    l4.beginPlay(at: date(24, 9, 40), intention: "B", genre: "lofi", track: "s1")
    l4.endPlay(at: date(24, 9, 50))
    l4.beginGap(reason: "away", at: date(24, 9, 50))
    l4.endGap(at: date(24, 10))
    l4.beginPlay(at: date(24, 10), intention: "B", genre: "lofi", track: "s1")
    l4.endPlay(at: date(24, 10, 10))
    l4.beginPlay(at: date(24, 11), intention: "C", genre: "lofi", track: "s1")
    l4.noteTrack("s2", at: date(24, 11, 5))
    l4.noteTrack("s3", at: date(24, 11, 5).addingTimeInterval(8))
    l4.endPlay(at: date(24, 11, 15))
    let day24 = LedgerStore.dayInterval(forLabel: date(24, 12), startHour: 6)
    let b4 = l4.blocks(in: day24, now: date(24, 12))
    check("blocks: the same task within 5 minutes is one block; a new task or a pause starts another",
          b4.blocks.map(\.intention) == ["A", "B", "B", "C"] && b4.blocks[0].playIDs.count == 2 && b4.pauses.count == 1,
          "\(b4.blocks.map(\.intention))")
    check("blocks: time played, songs with their minutes, genres",
          b4.blocks[0].seconds == 38 * 60 && b4.blocks[0].songs.map(\.id) == ["s1", "s2", "s3"]
          && b4.blocks[0].songs[0].seconds == 600 && b4.blocks[0].songs[1].seconds == 1200
          && b4.blocks[0].genreSeconds["lofi"] == 1800 && b4.blocks[0].genreSeconds["grooves"] == 480)
    check("a song skipped within seconds hands its time to the next one",
          b4.blocks[3].songs.map(\.id) == ["s1", "s3"] && b4.blocks[3].songs[1].seconds == 600, "\(b4.blocks[3].songs)")
    l4.renamePlays(b4.blocks[1].playIDs, to: "B2")
    check("rename a block", l4.blocks(in: day24, now: date(24, 12)).blocks[1].intention == "B2")
    let removed4 = l4.deletePlays(b4.blocks[0].playIDs)
    let afterDelete = l4.blocks(in: day24, now: date(24, 12)).blocks.map(\.intention)
    l4.restorePlays(removed4)
    check("delete a block, then undo", removed4.count == 2 && afterDelete == ["B2", "B", "C"]
          && l4.blocks(in: day24, now: date(24, 12)).blocks.map(\.intention) == ["A", "B2", "B", "C"])
    check("recent tasks, newest first", l4.recentIntentions() == ["C", "B", "B2", "A"], "\(l4.recentIntentions())")
    check("records from before the song list still read", (try? JSONStore.decoder().decode(PlayEntry.self, from: Data(
        #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":"2026-11-20T00:00:00Z","end":"2026-11-20T01:00:00Z","intention":"","genre":"lofi"}"#.utf8)))?.tracks == nil)

    // Gaps are listed but never counted
    l2.beginGap(reason: "away", at: date(22, 14))
    l2.endGap(at: date(22, 14, 12))
    let day22 = LedgerStore.dayInterval(forLabel: date(22, 12), startHour: 6)
    let rows = l2.rows(in: day22, now: date(22, 20))
    check("gap row present", rows.contains { $0.kind == .away })
    check("gap not counted", abs(l2.seconds(in: day22, now: date(22, 20)) - 3 * 3600) < 1)

    // Library: catalog + state, selection weights
    let lib = tmp.appendingPathComponent("Library")
    try? FileManager.default.createDirectory(at: lib.appendingPathComponent("tracks"), withIntermediateDirectories: true)
    var catalog = CatalogFile(version: 1, tracks: [])
    let loops: [(Double?, Double?)] = [(20, 260), (200, 100), (nil, nil)]
    for (i, id) in ["a", "b", "c"].enumerated() {
        FileManager.default.createFile(atPath: lib.appendingPathComponent("tracks/\(id).wav").path, contents: Data([0]))
        catalog.tracks.append(CatalogTrack(id: id, title: id.uppercased(), genre: i == 2 ? "lofi" : "electronic", file: "tracks/\(id).wav",
                                           durationSeconds: 300, gainDb: -3, bpm: 120, beatOffsetSeconds: 0.1, gridVerified: i == 0,
                                           modulationHz: 16, palette: nil, status: "inMix", flags: nil,
                                           loopStartSeconds: loops[i].0, loopEndSeconds: loops[i].1, loopSeamCorrelation: i == 0 ? 0.2 : nil,
                                           about: i == 0 ? CatalogAbout(vibe: CatalogText(en: "Hypnotic minimal techno", ko: "최면 같은 미니멀 테크노"),
                                                                        loop: CatalogText(en: "One synth pattern", ko: "신스 패턴 하나")) : nil))
    }
    try? FileManager.default.createDirectory(at: lib.appendingPathComponent("covers"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lib.appendingPathComponent("covers/a.jpg").path, contents: Data([0xFF, 0xD8]))
    catalog.tracks[0].cover = "covers/a.jpg"
    catalog.tracks[1].cover = "covers/missing.jpg"
    // Playlist "Recently added": b is the newest, then c, then a.
    catalog.tracks[0].addedAt = "2026-11-20T10:00:00Z"
    catalog.tracks[1].addedAt = "2026-11-23T10:00:00Z"
    catalog.tracks[2].addedAt = "2026-11-21T10:00:00Z"
    JSONStore.write(catalog, to: lib.appendingPathComponent("library.json"))
    let store = LibraryStore(paths: AppPaths(dataDir: tmp))
    check("catalog loads 3 tracks", store.tracks.count == 3)
    check("effect only on grid-verified tracks", store.track("a")?.modulationHz == 16 && store.track("b")?.modulationHz == nil)
    check("loop points read from the catalog", store.track("a")?.loopStart == 20 && store.track("a")?.loopEnd == 260
          && store.track("a")?.loopSeamCorrelation == 0.2)
    check("unusable or missing loop points: plays once", store.track("b")?.loopStart == nil && store.track("b")?.loopEnd == nil
          && store.track("c")?.loopStart == nil && store.track("c")?.loopSeamCorrelation == 0)
    let en = Strings(ko: false), ko = Strings(ko: true)
    check("a song lasts 30 min or more: whole loop passes (a: 300 s file, 240 s loop -> 33:00)",
          store.track("a")?.playLength == 1980 && store.track("b")?.playLength == 300,
          "a \(store.track("a")?.playLength ?? -1) b \(store.track("b")?.playLength ?? -1)")
    check("noise options: a name for every choice, a picture for every choice but Off (the switch)",
          en.noiseOptions.count == NoiseChoice.allCases.count && ko.noiseOptions.count == NoiseChoice.allCases.count
          && NoiseChoice.pictured == NoiseChoice.allCases.filter { $0 != .off }
          && en.noiseName(.ocean) == "Waves" && ko.noiseName(.stream) == "시냇물" && en.noiseName(.off) == "Off")
    check("focus pulse: a name and a hint for every level in both languages",
          [en.effectNames, ko.effectNames, en.pulseLevelHints, ko.pulseLevelHints].allSatisfy { $0.count == EffectChoice.allCases.count })
    check("a cover file in the library is the song's picture; a missing one falls back to colours",
          store.track("a")?.coverURL?.lastPathComponent == "a.jpg" && store.track("b")?.coverURL == nil && store.track("c")?.coverURL == nil)
    // Focus pulse plans: "follow" carries its beat map, "steady" a plain pulse; older catalogs
    // without pulseMode still need gridVerified.
    let pulseDir = tmp.appendingPathComponent("pulse", isDirectory: true)
    let pulseLib = pulseDir.appendingPathComponent("Library", isDirectory: true)
    try? FileManager.default.createDirectory(at: pulseLib.appendingPathComponent("tracks"), withIntermediateDirectories: true)
    var pulseCatalog = CatalogFile(version: 1, tracks: [])
    for id in ["f", "s", "old"] {
        FileManager.default.createFile(atPath: pulseLib.appendingPathComponent("tracks/\(id).wav").path, contents: Data([0]))
        var item = CatalogTrack(id: id, title: id, genre: "lofi", file: "tracks/\(id).wav", durationSeconds: 300, gainDb: 0, bpm: 97,
                                beatOffsetSeconds: 0.2, gridVerified: false, modulationHz: 16.2, palette: nil, status: "inMix", flags: nil)
        if id == "f" { item.pulseMode = "follow"; item.beatTimes = [0.2, 0.82, 1.44, 2.05]; item.pulseCyclesPerBeat = 10 }
        if id == "s" { item.pulseMode = "steady"; item.modulationHz = 16; item.beatTimes = [1, 2] }
        pulseCatalog.tracks.append(item)
    }
    JSONStore.write(pulseCatalog, to: pulseLib.appendingPathComponent("library.json"))
    let pulseStore = LibraryStore(paths: AppPaths(dataDir: pulseDir))
    let follow = pulseStore.track("f"), steady = pulseStore.track("s"), old = pulseStore.track("old")
    check("pulse plans: follow keeps its beats, steady pulses without them, old catalogs need the grid",
          follow?.modulationHz == 16.2 && follow?.beatTimes == [0.2, 0.82, 1.44, 2.05] && follow?.pulseCyclesPerBeat == 10
          && steady?.modulationHz == 16 && steady?.beatTimes == nil && steady?.pulseCyclesPerBeat == 0
          && old?.modulationHz == nil && old?.beatTimes == nil)
    check("rain, waves and stream are the recordings", NoiseChoice.allCases.filter(\.isRecording) == [.rain, .ocean, .stream])
    check("one-line description in both languages, none when the catalog has none",
          store.track("a")?.vibe(ko: false) == "Hypnotic minimal techno" && store.track("a")?.vibe(ko: true) == "최면 같은 미니멀 테크노"
          && store.track("a")?.about?.loop?.text(ko: true) == "신스 패턴 하나" && store.track("b")?.vibe(ko: false) == nil)
    check("tempo read; 120 BPM is not a slow song", store.track("a")?.bpm == 120 && store.track("a")?.isSlow == false)
    check("playlist status line: songs counted, one song said once",
          en.statusShuffled(1) == "1 song · shuffled" && en.statusInOrder(27) == "27 songs · in list order"
          && ko.statusShuffled(27) == "27곡 · 섞어서" && ko.statusInOrder(3) == "3곡 · 목록 순서대로")
    check("genre filter", store.playable(for: .lofi).map(\.id) == ["c"])
    store.toggleLike("a")
    var counts = ["a": 0, "b": 0, "c": 0]
    for _ in 0..<3000 { if let t = store.pickNext(for: .mix, avoiding: [], learn: false) { counts[t.id, default: 0] += 1 } }
    let ratio = Double(counts["a"]!) / Double(max(1, counts["b"]!))
    check("liked track plays about twice as often", ratio > 1.7 && ratio < 2.3, String(format: "ratio %.2f", ratio))
    check("the song on now never comes right back",
          (0..<200).allSatisfy { _ in store.pickNext(for: .mix, avoiding: ["a", "b"], learn: false)?.id != "b" })
    // Shuffle: the latest half of what can play waits its turn.
    let shuffleDir = tmp.appendingPathComponent("shuffle", isDirectory: true)
    let shuffleLib = shuffleDir.appendingPathComponent("Library", isDirectory: true)
    try? FileManager.default.createDirectory(at: shuffleLib.appendingPathComponent("tracks"), withIntermediateDirectories: true)
    var shuffleCatalog = CatalogFile(version: 1, tracks: [])
    for i in 0..<11 {
        let id = "s\(i)"
        FileManager.default.createFile(atPath: shuffleLib.appendingPathComponent("tracks/\(id).wav").path, contents: Data([0]))
        shuffleCatalog.tracks.append(CatalogTrack(id: id, title: id, genre: i == 10 ? "lofi" : "electronic", file: "tracks/\(id).wav",
                                                  durationSeconds: 300, gainDb: 0, bpm: 120, beatOffsetSeconds: 0, gridVerified: false,
                                                  modulationHz: nil, palette: nil, status: "inMix", flags: nil))
    }
    JSONStore.write(shuffleCatalog, to: shuffleLib.appendingPathComponent("library.json"))
    let shuffleStore = LibraryStore(paths: AppPaths(dataDir: shuffleDir))
    // Electronic has 10 songs, so the newest 5 wait. Repeats in the list and other genres don't use up the 5.
    let lately = ["s9", "s0", "s10", "s1", "s1", "s2", "s3", "s3", "s4"]
    var shufflePicks = Set<String>()
    for _ in 0..<400 { if let t = shuffleStore.pickNext(for: .electronic, avoiding: lately, learn: false) { shufflePicks.insert(t.id) } }
    check("shuffle: the newest half waits, the rest all come up", shufflePicks == ["s5", "s6", "s7", "s8", "s9"], "\(shufflePicks.sorted())")
    for _ in 0..<4 { store.recordListen("b", listened: 20, skipped: true, completed: false) }
    check("skips lower fit", (store.track("b")?.fit ?? 1) < 0.3, String(format: "fit %.2f", store.track("b")?.fit ?? -1))
    store.remove("c")
    check("remove hides from Mix", store.playable(for: .mix).allSatisfy { $0.id != "c" })
    store.undoRemove()
    check("undo restores", store.playable(for: .mix).contains { $0.id == "c" })
    check("songs skipped early more than heard through come up less", store.lessPlayed().map(\.id) == ["b"])
    store.clearLearning(["b"])
    check("clearing what was learned brings them back", store.lessPlayed().isEmpty && store.track("b")?.state.skips == 0)
    for _ in 0..<4 { store.recordListen("b", listened: 20, skipped: true, completed: false) }
    let reloaded = LibraryStore(paths: AppPaths(dataDir: tmp))
    check("state persists (like, skips)", reloaded.track("a")?.liked == true && reloaded.track("b")?.state.skips == 4)

    // Playlist order. Catalog: a, b electronic, c lo-fi; a is liked.
    check("default order: by genre (Lo-fi, Grooves, Electronic), catalog order inside",
          store.ordered(for: .mix, sort: .standard).map(\.id) == ["c", "a", "b"])
    check("recently added first", store.ordered(for: .mix, sort: .recent).map(\.id) == ["b", "c", "a"])
    check("liked first, then the default order", store.ordered(for: .mix, sort: .liked).map(\.id) == ["a", "c", "b"])
    check("by name", store.ordered(for: .mix, sort: .name).map(\.id) == ["a", "b", "c"])
    check("in order: next wraps to the top, previous to the bottom, no song yet starts at the top",
          store.nextInOrder(after: "b", for: .mix, sort: .standard)?.id == "c"
          && store.previousInOrder(before: "c", for: .mix, sort: .standard)?.id == "b"
          && store.nextInOrder(after: nil, for: .mix, sort: .standard)?.id == "c"
          && store.nextInOrder(after: "a", for: .electronic, sort: .standard)?.id == "b")
    store.remove("a")
    check("a song taken out of the list still has neighbours: the one after it comes next",
          store.nextInOrder(after: "a", for: .mix, sort: .standard)?.id == "b" && store.hiddenTracks().map(\.id) == ["a"])
    store.restore("a")
    check("play again puts it back", store.playable(for: .mix).contains { $0.id == "a" } && store.hiddenTracks().isEmpty)

    // A new song plays like the rest and wears New until it is first played.
    let newDir = tmp.appendingPathComponent("new", isDirectory: true)
    let newLib = newDir.appendingPathComponent("Library", isDirectory: true)
    try? FileManager.default.createDirectory(at: newLib.appendingPathComponent("tracks"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: newLib.appendingPathComponent("tracks/n.wav").path, contents: Data([0]))
    JSONStore.write(CatalogFile(version: 1, tracks: [
        CatalogTrack(id: "n", title: "N", genre: "grooves", file: "tracks/n.wav", durationSeconds: 300, gainDb: 0, bpm: 120,
                     beatOffsetSeconds: 0, gridVerified: false, modulationHz: nil, palette: nil, status: "new", flags: nil)
    ]), to: newLib.appendingPathComponent("library.json"))
    let newStore = LibraryStore(paths: AppPaths(dataDir: newDir))
    check("a new song plays and is marked New", newStore.playable(for: .mix).map(\.id) == ["n"] && newStore.track("n")?.isNew == true)
    newStore.markPlayed("n")
    check("its first play takes New off", newStore.track("n")?.isNew == false && newStore.track("n")?.status == .inMix)

    // Formatting
    check("clock h:mm:ss", Fmt.clock(2 * 3600 + 56 * 60 + 18) == "2:56:18")
    check("clock m:ss", Fmt.clock(108) == "1:48")
    check("duration en/ko", Fmt.duration(176 * 60, ko: false) == "2h 56m" && Fmt.duration(176 * 60, ko: true) == "2시간 56분")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    return failures == 0 ? 0 : 1
}

@main
enum AppLogicChecks {
    static func main() async {
        let code = await runChecks()
        exit(code)
    }
}
