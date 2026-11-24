import Foundation

/// All user-facing copy in English (default) and Korean.
struct Strings {
    let ko: Bool
    private func p(_ en: String, _ k: String) -> String { ko ? k : en }

    // Panel
    func todayDate(_ date: Date) -> String { p("Today · ", "오늘 · ") + Fmt.dayShort(date, ko: ko) }
    var today: String { p("Today", "오늘") }
    var timerAndSound: String { p("Timer & Sound", "타이머와 소리") }
    var chipAria: String { p("Timer and sound", "타이머와 소리") }
    var menu: String { p("Menu", "메뉴") }
    var history: String { p("History", "기록") }
    var historyAria: String { p("Open today in History", "오늘 기록 열기") }
    var dateAria: String { p("Open this month in History", "이번 달 기록 열기") }
    var openPlaylist: String { p("Open the playlist", "재생 목록 열기") }
    var back: String { p("Back", "뒤로") }
    var backToPlayer: String { p("Back to the player", "플레이어로 돌아가기") }
    var sections: String { p("Sections", "화면") }
    var play: String { p("Play", "재생") }
    var pause: String { p("Pause", "일시정지") }
    var prevMusic: String { p("Previous music", "이전 음악") }
    var nextMusic: String { p("Next music", "다음 음악") }
    var prevTrack: String { p("Previous track", "이전 곡") }
    var nextTrack: String { p("Next track", "다음 곡") }
    var like: String { p("Like · plays more often", "좋아요 · 더 자주 나와요") }
    var intentPlaceholder: String { p("What are you working on?", "지금 뭐 해요?") }
    var done: String { p("Done", "완료") }
    var callNotice: String { p("Paused for your call · back when it ends", "통화 중이라 멈췄어요 · 끝나면 다시 재생") }
    var awayNotice: String { p("Paused while you were away", "자리를 비워서 멈췄어요") }
    func otherSoundNotice(_ app: String) -> String { ko ? "\(app) 소리가 나서 멈췄어요" : "Paused · \(app) is playing" }
    var headphonesNotice: String { p("Headphones off · resumes when back", "헤드폰이 빠져서 멈췄어요 · 연결하면 재생") }
    var noTracks: String { p("No tracks in Mix yet", "재생 목록에 곡이 없어요") }
    func timerLeft(_ t: String) -> String { ko ? "타이머 · \(t) 남음" : "Timer · \(t) left" }
    func timerIdle(_ minutes: Int) -> String { ko ? "타이머 \(minutes)분" : "Timer \(minutes) min" }
    func pomodoroIdle(_ focus: Int, _ rest: Int) -> String { ko ? "포모도로 \(focus) / \(rest)" : "Pomodoro \(focus) / \(rest)" }
    func focusRound(_ n: Int, _ t: String) -> String { ko ? "집중 \(n)회차 · 남은 \(t)" : "Focus \(n) · \(t) left" }
    func breakLeft(_ t: String) -> String { ko ? "휴식 · 남은 \(t)" : "Break · \(t) left" }
    func longBreakLeft(_ t: String) -> String { ko ? "긴 휴식 · 남은 \(t)" : "Long break · \(t) left" }
    var breakWord: String { p("Break", "휴식") }
    var onCall: String { p("On a call", "통화 중") }
    var away: String { p("Away", "자리 비움") }
    var headphonesOff: String { p("Headphones off", "헤드폰 끊김") }
    var otherSoundTag: String { p("Other sound", "다른 소리") }

    // Timer & Sound
    var pulse: String { p("Focus pulse", "집중 떨림") }
    var pulseWhy: String {
        p("A faint pulse on the beat that keeps your attention from drifting.",
          "박자에 맞춘 미세한 떨림이 주의가 흩어지지 않게 잡아줘요.")
    }
    /// How each level sounds, in `EffectChoice` order; shown beside the Focus pulse title.
    var pulseLevelHints: [String] {
        ko ? ["원래 음악 그대로", "은은하게", "적당히", "또렷하게"] : ["Music as it is", "Subtle", "Moderate", "Clear"]
    }
    var effectNames: [String] { ko ? ["끔", "약하게", "보통", "강하게"] : ["Off", "Low", "Medium", "High"] }
    var volume: String { p("Volume", "볼륨") }
    var noise: String { p("Noise", "배경 소음") }
    var noiseWhy: String { p("Covers sudden sounds around you.", "주변에서 갑자기 나는 소리를 덮어줘요.") }
    /// The switch line in the Noise card.
    var noiseRow: String { p("Play under the music", "음악 밑에 깔기") }
    /// In `NoiseChoice.allCases` order.
    var noiseOptions: [String] {
        ko ? ["끔", "빗소리", "파도", "시냇물", "브라운", "핑크", "화이트"] : ["Off", "Rain", "Waves", "Stream", "Brown", "Pink", "White"]
    }
    func noiseName(_ choice: NoiseChoice) -> String { noiseOptions[NoiseChoice.allCases.firstIndex(of: choice) ?? 0] }
    var noiseLevel: String { p("Level", "크기") }
    var playMode: String { p("Play mode", "재생 방식") }
    var modes: [(String, String)] {
        ko ? [("자유", "시간 제한 없이 재생"), ("타이머", "정한 시간만큼 재생"), ("포모도로", "집중과 휴식을 반복")]
           : [("No limit", "Plays until you stop"), ("Timer", "Plays for a set time"), ("Pomodoro", "Focus and breaks, repeated")]
    }
    func minutes(_ n: Int) -> String { ko ? "\(n)분" : "\(n) min" }
    var custom: String { p("Custom", "직접") }
    var whenEnds: String { p("When it ends", "끝나면") }
    var timerEnds: [String] { ko ? ["멈춤", "계속 재생"] : ["Stop", "Keep playing"] }
    /// The long-break switch line: name and second line.
    var longBreak: (String, String) { ko ? ("긴 휴식", "4회마다 15분") : ("Long break", "15 min, every 4 rounds") }
    var breakMusic: String { p("During breaks", "휴식 중 음악") }
    var breakOptions: [String] { ko ? ["멈춤", "작게"] : ["Pause", "Quieter"] }
    var focusWord: String { p("Focus", "집중") }

    // Playlist (the grown panel's middle tab)
    var playlist: String { p("Playlist", "재생 목록") }
    var whatPlays: String { p("What plays", "틀 음악") }
    var newTag: String { p("New", "새 곡") }
    var dontPlay: String { p("Don't play this song", "이 곡 안 틀기") }
    var notPlaying: String { p("Not playing", "안 트는 곡") }
    var playAgain: String { p("Play again", "다시 틀기") }
    func playSong(_ title: String) -> String { ko ? "\(title) 틀기" : "Play \(title)" }
    var playlistEmpty: String { p("No songs here.", "여기엔 곡이 없어요.") }
    var sortLabel: String { p("Sort", "정렬") }
    /// The sort menu's lines.
    func sortName(_ sort: PlaylistSort) -> String {
        switch sort {
        case .standard: return p("Default (by genre)", "기본 (장르별)")
        case .recent: return p("Recently added", "최근 추가")
        case .liked: return p("Liked first", "♥ 먼저")
        case .name: return p("Name", "이름순")
        }
    }
    /// The chosen order beside "Sort".
    func sortShort(_ sort: PlaylistSort) -> String {
        switch sort {
        case .standard: return p("Default", "기본")
        case .recent: return p("Recent", "최근 추가")
        case .liked: return p("Liked", "♥ 먼저")
        case .name: return p("Name", "이름순")
        }
    }
    func songs(_ n: Int) -> String { ko ? "\(n)곡" : (n == 1 ? "1 song" : "\(n) songs") }
    func statusShuffled(_ n: Int) -> String { songs(n) + p(" · shuffled", " · 섞어서") }
    func statusInOrder(_ n: Int) -> String { songs(n) + p(" · in list order", " · 목록 순서대로") }
    var statusRepeat: String { p("This song only", "이 곡만 계속 틀어요") }
    var shuffle: String { p("Shuffle", "섞어서 틀기") }
    var repeatOne: String { p("Repeat this song", "이 곡만 계속") }
    func onOff(_ on: Bool) -> String { on ? p("on", "켜짐") : p("off", "꺼짐") }
    var songPosition: String { p("Song position", "곡 위치") }
    var whyAria: String { p("Why this music helps you focus", "왜 집중에 좋은가요") }
    var whyTitle: String { p("Why does this music help you focus?", "왜 집중에 좋은가요?") }
    func whySub(_ n: Int) -> String { ko ? "\(n)곡 모두 이렇게 만들었어요." : "All \(n) songs are made this way." }
    var close: String { p("Close", "닫기") }
    /// The ⓘ card: name and why it helps. Every song is made this way, so it is said once, here.
    var reasonPulse: (String, String) {
        ko ? ("박자에 맞춘 떨림", "ADHD 집중용으로 넣은 미세한 떨림이에요. 주의가 덜 흩어져요.")
           : ("A pulse on the beat", "A faint pulse made for ADHD focus. Attention drifts less.")
    }
    var reasonVoice: (String, String) {
        ko ? ("말소리 없음", "가사가 있으면 생각이 말로 끌려가요. 이 곡엔 말소리가 없어요.")
           : ("No voices", "Lyrics pull your mind into words. There are none here.")
    }
    var reasonCalm: (String, String) {
        ko ? ("튀는 순간 없음", "ADHD 뇌는 갑자기 나는 소리에 더 크게 반응해요. 그런 순간이 없어요.")
           : ("No surprises", "ADHD brains react more to sudden sounds. Nothing jumps out here.")
    }
    var reasonLoop: (String, String) {
        ko ? ("멜로디 없는 반복", "한 가지 패턴이 계속 돌아요. 따라갈 멜로디가 없어 배경에 머물러요.")
           : ("Just a loop", "One pattern on repeat, no tune to follow. It stays in the background.")
    }

    // History
    var now: String { p("now", "진행 중") }
    var thisWeek: String { p("This week", "이번 주") }
    var thisMonth: String { p("This month", "이번 달") }

    // Menu
    var menuHistory: String { p("History", "기록") }
    var menuPlaylist: String { p("Playlist", "재생 목록") }
    var menuSettings: String { p("Settings…", "설정…") }
    var menuQuit: String { p("Quit", "종료") }

    // History window
    func dayStarts(_ hour: Int) -> String {
        if hour == 0 { return p("Days start at midnight", "하루는 자정에 시작해요") }
        return ko ? "하루는 오전 \(hour)시에 시작해요" : "Days start at \(hour):00 AM"
    }
    var prevMonth: String { p("Previous month", "이전 달") }
    var nextMonth: String { p("Next month", "다음 달") }
    var dayHint: String { p("Click a day to open it", "날짜를 누르면 그날로 가요") }
    var prevDay: String { p("Previous day", "전날") }
    var nextDay: String { p("Next day", "다음 날") }
    var toMonth: String { p("Back to the month", "달력으로") }
    func monthName(_ date: Date) -> String { Fmt.monthOnly(date, ko: ko) }
    var stats: [String] { ko ? ["합계", "기록한 날", "하루 평균", "가장 긴 날"] : ["Total", "Days", "Daily average", "Longest day"] }
    var edit: String { p("Edit", "수정") }
    var delete: String { p("Delete", "삭제") }
    var emptyDay: String { p("Nothing played on this day.", "이날은 기록이 없어요.") }
    var futureDay: String { p("This day hasn't come yet.", "아직 오지 않은 날이에요.") }
    var awayRow: String { p("Away · not counted", "자리 비움 · 기록 안 됨") }
    var callRow: String { p("Call · not counted", "통화 · 기록 안 됨") }
    func daysCount(_ n: Int) -> String { ko ? "\(n)일" : "\(n)" }
    func weekdaySymbols(weekStart: WeekStart) -> [String] {
        let base = ko ? ["일", "월", "화", "수", "목", "금", "토"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return weekStart == .monday ? Array(base[1...]) + [base[0]] : base
    }
    func weekdayLetters(weekStart: WeekStart) -> [String] {
        let base = ko ? ["일", "월", "화", "수", "목", "금", "토"] : ["S", "M", "T", "W", "T", "F", "S"]
        return weekStart == .monday ? Array(base[1...]) + [base[0]] : base
    }

    // Settings window
    var settings: String { p("Settings", "설정") }
    var general: String { p("General", "일반") }
    var automatic: String { p("Automatic", "자동으로") }
    var showInMenuBar: String { p("Show in menu bar", "메뉴바에 보일 것") }
    var playback: String { p("Playback", "재생") }
    var language: String { p("Language", "언어") }
    var openAtLogin: String { p("Open at login", "Mac 켜면 자동 실행") }
    var showInDock: String { p("Show in Dock", "Dock에 아이콘 보이기") }
    var shortcut: String { p("Play/pause shortcut", "재생·멈춤 단축키") }
    var change: String { p("Change", "바꾸기") }
    var pressKeys: String { p("Press keys…", "키를 누르세요…") }
    var mediaKeys: String { p("Play / pause key", "재생·멈춤 키") }
    var mediaOptions: [String] { ko ? ["재생 중일 때", "항상", "끔"] : ["While playing", "Always", "Off"] }
    var automaticRows: [(String, String)] {
        ko ? [("자리 비우면 멈춤", "화면 잠금·잠자기 · 돌아오면 다시 재생"),
              ("통화하면 멈춤", "마이크나 카메라가 켜지면"),
              ("다른 소리 나면 멈춤", "유튜브·영상·회의 · 소리가 끝나면 다시 재생"),
              ("헤드폰 빼면 멈춤", "다시 연결하면 이어서 재생")]
           : [("Pause when I step away", "Screen lock or sleep · resumes when you're back"),
              ("Pause during calls", "When the mic or camera turns on"),
              ("Pause when other sound plays", "YouTube, videos, meetings · resumes when it stops"),
              ("Pause when headphones disconnect", "Resumes when they reconnect")]
    }
    var learnRow: (String, String) {
        ko ? ("넘긴 곡 학습", "1분 안에 다음으로 넘긴 곡은 덜 나와요") : ("Learn from skips", "Songs you skip within a minute come up less")
    }
    var menuBarOptions: [(String, String)] {
        ko ? [("아이콘 + 오늘 합계", "기본 · 멈추면 흐려져요"), ("아이콘만", "가장 조용하게")]
           : [("Icon + today's total", "Default · dims when paused"), ("Icon only", "Quietest")]
    }
    var defaultMusic: String { p("Default music", "기본 음악") }
    var defaultEffect: String { p("Default pulse", "집중 떨림 기본값") }
    var fadeInOut: String { p("Fade in and out", "시작·멈출 때 소리를 서서히") }
    var dayStartsAt: String { p("Day starts at", "하루 시작") }
    func dayStartOption(_ hour: Int) -> String {
        if hour == 0 { return p("Midnight", "자정") }
        return ko ? "오전 \(hour):00" : "\(hour):00 AM"
    }
    var weekStartsOn: String { p("Week starts on", "한 주 시작") }
    var weekOptions: [String] { ko ? ["월요일", "일요일"] : ["Monday", "Sunday"] }
    var loginFailed: String { p("Couldn't change the login item. Move the app to Applications and try again.", "로그인 항목을 바꾸지 못했어요. 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 해 주세요.") }

    // History: the week strip, the day's timetable, by task and music
    var week: String { p("Week", "주") }
    var month: String { p("Month", "월") }
    var todayButton: String { p("Today", "오늘") }
    var todayTag: String { p("TODAY", "오늘") }
    var total: String { p("Total", "합계") }
    var dailyAvg: String { p("Daily avg", "하루 평균") }
    func lastWeekTotal(_ t: String) -> String { ko ? "지난주 \(t)" : "last week \(t)" }
    /// The month before, by name: "October 31h 5m" · "10월 31시간 5분".
    func monthTotal(_ month: String, _ t: String) -> String { "\(month) \(t)" }
    func emptyMonth(_ month: String) -> String { ko ? "\(month)엔 기록이 없어요." : "Nothing played in \(month)." }
    func weekTitle(_ range: String, offset: Int) -> String {
        if offset == 0 { return ko ? "이번 주 · \(range)" : "This week · \(range)" }
        if offset == -1 { return ko ? "지난주 · \(range)" : "Last week · \(range)" }
        return range
    }
    func dayTitle(_ date: Date, today: Bool) -> String { Fmt.dayLong(date, ko: ko) + (today ? p(" · Today", " · 오늘") : "") }
    var longestStretch: String { p("Longest stretch", "가장 길게 이어진 집중") }
    var byTask: String { p("By task", "할 일별") }
    var music: String { p("Music", "들은 음악") }
    var noTask: String { p("No task written", "할 일 적지 않음") }
    var byTaskMonth: String { p("By task this month", "이번 달 할 일별") }
    var musicMonth: String { p("Music this month", "이번 달 들은 음악") }
    var daysWithFocus: String { p("Days with focus", "기록한 날") }
    var longestDay: String { p("Longest day", "가장 긴 날") }
    func dayCount(_ n: Int) -> String { ko ? "\(n)일" : (n == 1 ? "1 day" : "\(n) days") }
    var less: String { p("Less", "적게") }
    var more: String { p("More", "많이") }
    func pauseLabel(call: Bool, _ minutes: String) -> String { (call ? p("Call", "통화") : p("Away", "자리 비움")) + " · " + minutes }
    func dayStartsShort(_ hour: Int) -> String {
        if hour == 0 { return p("Days start at midnight", "하루는 자정에 시작") }
        return ko ? "하루는 오전 \(hour)시에 시작" : "Days start at \(hour):00 AM"
    }
    var dayStartTitle: String { p("A day starts at", "하루 시작") }
    func hourShort(_ h: Int) -> String { h == 0 ? p("12 AM", "자정") : (ko ? "\(h)시" : "\(h) AM") }
    func dayStartWhy(_ hour: Int) -> String {
        if hour == 0 { return p("Each day runs midnight to midnight.", "하루는 자정부터 자정까지예요.") }
        return ko ? "새벽 \(hour)시 전에 한 일은 전날 기록으로 들어가요. 밤늦게 일해도 하루가 둘로 나뉘지 않아요."
                  : "Work before \(hour) AM counts toward the day before, so a late night stays one day."
    }
    var recentTasks: String { p("Recent tasks", "최근 할 일") }
    var whatWasIt: String { p("What was it?", "무슨 일이었나요?") }
    var deleteWord: String { p("Delete", "지우기") }
    var recordingNow: String { p("Recording now — rename it on the player", "지금 기록 중이에요 · 이름은 메인 화면에서") }
    func deletedBlock(_ range: String) -> String { ko ? "\(range) 기록을 지웠어요" : "Deleted \(range)" }
    var undo: String { p("Undo", "되돌리기") }

    // Settings: five parts on the left, one page at a time
    var settingsPages: [String] { ko ? ["재생", "자동으로 멈춤", "메뉴바와 시작", "키보드", "기록"] : ["Playback", "Pauses by itself", "Menu bar & startup", "Keyboard", "History"] }
    var settingsDescs: [String] {
        ko ? ["켤 때 무엇을 틀지, 어떤 곡을 덜 틀지 정해요.",
              "자리를 비우거나 통화하거나 다른 소리가 나면 음악이 멈추고, 그 시간은 기록에서 빠져요. 상황이 끝나면 이어서 틀어요.",
              "메뉴바에 무엇을 보일지, Mac을 켤 때 어떻게 할지 정해요.",
              "패널을 열지 않고도 음악을 켜고 꺼요.",
              "기록에서 하루와 한 주가 어디서 시작할지 정해요. 기록 화면에서도 바로 바꿀 수 있어요."]
           : ["What plays when you start, and which songs come up less.",
              "The music stops when you step away, take a call or play something else, and that time stays out of History. It comes back on when you do.",
              "What the menu bar shows, and what happens when the Mac starts.",
              "Start and stop the music without opening the panel.",
              "Where a day and a week begin in History. You can change this right in History too."]
    }
    var musicAtStart: String { p("Music at start", "처음 틀 음악") }
    var pulseAtStart: String { p("Focus pulse at start", "처음 집중 떨림") }
    var fadeWhy: String { p("No sudden starts or cuts to jolt you", "갑자기 켜지거나 끊겨서 놀라지 않게") }
    var lessNow: String { p("Coming up less now", "지금 덜 나오는 곡") }
    var clearLearning: String { p("Clear", "기록 지우기") }
    var noneLess: String { p("None", "없어요") }
    func andMore(_ n: Int) -> String { ko ? "외 \(n)곡" : "+\(n) more" }
    var pauseCards: [(String, String)] {
        ko ? [("자리 비우면 멈춤", "화면을 잠그거나 잠자기에 들면. 돌아오면 다시 재생"),
              ("통화하면 멈춤", "마이크나 카메라가 켜지면. 통화가 끝나면 다시 재생"),
              ("다른 소리 나면 멈춤", "유튜브·영상·회의 소리가 2초 넘게 나면. 조용해지면 다시 재생"),
              ("헤드폰 빼면 멈춤", "스피커로 새어 나가지 않게. 다시 연결하면 이어서")]
           : [("Pause when I step away", "Screen lock or sleep. Back on when you return."),
              ("Pause during calls", "When the mic or camera turns on. Back on when the call ends."),
              ("Pause when other sound plays", "YouTube, videos, meetings: sound for 2 seconds. Back on when it is quiet."),
              ("Pause when headphones disconnect", "So it never spills out of the speakers. Back on when they reconnect.")]
    }
    var seenOnPlayer: String { p("On the player it looks like this", "메인 화면에서는 이렇게 보여요") }
    var noticeOpensHere: String { p("Clicking it opens this page with that card marked", "누르면 이 페이지가 열리고 그 카드가 표시돼요") }
    var noticeSample: String { p("Paused · Chrome is playing", "Chrome 소리가 나서 멈췄어요") }
    var openAtLoginWhy: String { p("Ready in the menu bar when the Mac starts", "Mac을 켜면 메뉴바에 바로 준비돼요") }
    var showInDockWhy: String { p("Off: it lives only in the menu bar", "끄면 메뉴바에만 있어요") }
    var shortcutTitle: String { p("Play / pause anywhere", "어디서나 재생·멈춤") }
    var shortcutWhy: String { p("Works in every app, panel closed", "패널을 닫고 다른 앱을 쓰는 중에도") }
    var spaceTitle: String { p("Space while the panel is open", "패널이 열려 있을 때 스페이스바") }
    var spaceWhy: String { p("Plays or pauses, like other music apps", "다른 음악 앱처럼 재생·멈춤") }
    var mediaWhy: String { p("While playing: it won't take over other apps' music", "'재생 중일 때'면 다른 앱 음악을 뺏지 않아요") }
    var nightExample: String { p("work at 1 AM → the day before", "새벽 1시 작업 → 전날") }
    var newDay: String { p("a new day", "새 하루") }
    var weekStartWhy: String { p("The first day of the week strip in History", "기록 화면 주 띠의 첫 요일") }
    var alsoInHistory: String { p("In History, \u{2018}Days start at · Change\u{2019} opens the same choice", "기록 화면의 '하루는 … 시작 · 바꾸기'에서도 같은 걸 고를 수 있어요") }
    var changeInSettings: String { p("Change in Settings", "설정에서 바꾸기") }
}
