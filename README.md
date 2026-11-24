# ADHD Music

Plain, steady music for focused work. A free menu bar app for macOS, made for people with ADHD.

**Download:** https://adhdmusic.app/download (free, about 460 MB, macOS 26 or later, Apple silicon)

[한국어 안내는 아래에 있어요.](#한국어)

<img src="site/assets/main-en.png" alt="The ADHD Music player" width="320">

## What it is

ADHD Music lives in your Mac's menu bar and plays music that stays in the background. Press play and get to work.

It comes with 27 songs in Lo-fi (12), Grooves (8) and Electronic (7). Each one plays as a seamless 30-minute stretch.

## Why it helps you focus

- **No voices.** Lyrics pull your mind into words. There are none here.
- **No surprises.** ADHD brains react more to sudden sounds. Nothing jumps out here.
- **Just a loop.** One pattern on repeat, no tune to follow. It stays in the background.
- **A pulse on the beat.** A faint, steady pulse locked to the beat of every song. You choose how strong it is.

## What it does

- **Pauses by itself** when you step away, during calls, when your headphones come off, and when another app plays sound, like a YouTube video. Then it plays again.
- **Background sounds:** rain, waves, stream, and brown, pink or white noise under the music.
- **Timer, pomodoro or no limit.**
- **Today's focus time** in the menu bar. It only counts while music plays.
- **History:** a week strip, a timeline of your day, time per task and the music you heard, plus a month view.
- **Playlist:** one list, four ways to sort it, shuffle that keeps songs you just heard from coming back, songs you like more often, and one song on repeat when you want it.
- **Learns what you skip.** Songs you skip early come up less.
- **Keyboard:** the space bar plays and pauses; a global shortcut and the media keys work too.
- **Private.** No account, no analytics. Your history stays on your Mac.
- English and Korean.

<img src="site/assets/history-en.png" alt="History: week strip, day timeline, time per task and the music you heard" width="720">

## Install

1. Download the .dmg: https://adhdmusic.app/download
2. Open it and drag ADHD Music into Applications.
3. Open ADHD Music. It appears in your menu bar.
4. macOS asks once for System Audio Recording. Allow it: that is how the music pauses while a YouTube video plays. Nothing is recorded.

Requires macOS 26 or later on a Mac with Apple silicon.

## Automatic updates

The app you download from adhdmusic.app keeps itself up to date. About once a day it checks https://adhdmusic.app/appcast.xml. When there is a new version, it downloads it in the background (usually a small update), checks its signature, and installs it at a quiet moment: when the panel is closed and no music has played for 15 minutes, or when you quit the app. Nothing pops up. The check sends only the app's version number.

Updates use [Sparkle](https://sparkle-project.org). Builds you make yourself (below) don't update themselves, except a website build you sign and publish with your own feed.

## Build from source

The songs and their covers are not in this repository (see [ASSETS.md](ASSETS.md)). A build from this code starts with an empty playlist until you add your own songs ([Add your own songs](#add-your-own-songs)).

You need:

- macOS 26 or later on Apple silicon
- Xcode 26 or later, set as the active developer directory: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (the Command Line Tools alone lack `actool`, which builds the app icon)
- To add songs: Python 3.9 to 3.12 (macOS's own `/usr/bin/python3` is 3.9) and ffmpeg (`brew install ffmpeg`)

### Build the app

```bash
git clone https://github.com/lazydevz-inc/adhd-music.git
cd adhd-music
Scripts/build-app.sh --allow-missing-noise
open "dist/ADHD Music.app"
```

`--allow-missing-noise` builds without the rain, waves and stream loops, which are not in the repository either; those three stay silent. Brown, pink and white noise are made by the app and always work. To include the three loops, put seamless stereo FLAC loops at `Audio/Noise/LoopsShare/rain.flac`, `ocean.flac` and `stream.flac` (48,000 samples per second, the rate the app plays at) and build without the flag.

The script signs the app with your Apple Development certificate when you have one, and ad hoc otherwise. With ad hoc signing, macOS asks again for System Audio Recording after every build.

| Command | Result |
| --- | --- |
| `Scripts/build-app.sh` | `dist/ADHD Music.app`, app id `app.adhdmusic.local`, data in `~/Library/Application Support/Focus Music/` |
| `Scripts/build-app.sh --dev` | `build/Focus Music Dev.app`, app id `app.adhdmusic.local.dev`, data in `~/Library/Application Support/Focus Music Dev/` |
| add `--stub` | compiles against a silent stand-in for the sound engine (`Tests/Stubs/AudioEngineStub.swift`) |
| `Scripts/build-app.sh --share` | the website build with automatic updates (see [Make the .dmg](#make-the-dmg)) |
| `Scripts/build-app.sh --mas` | the Mac App Store build (see [Scripts/mas/README.md](Scripts/mas/README.md)) |

Your own builds keep their records, likes, learning and song library apart from the downloaded app, which uses `~/Library/Application Support/ADHD Music/`.

To try things without touching your records, start the app with its own data folder. Other development options: `--mute`, `--volume 0.03`, `--autoplay`, `--seed-demo` (a sample day of history), `--open-panel`, `--lang ko`, `--dark`, `--preview <page>`, `--scenario`, `--sound-log`.

```bash
"dist/ADHD Music.app/Contents/MacOS/FocusMusic" --data-dir ~/adhd-music-test --seed-demo --open-panel
```

### Add your own songs

1. Set up the song tools once:

   ```bash
   /usr/bin/python3 -m venv .venv-audio
   .venv-audio/bin/pip install -r Scripts/requirements-audio.txt
   ```

2. Put your WAV or FLAC files in `Audio/Songs/`. Git ignores `Audio/`.
3. Copy `Scripts/library-sources.example.json` to `Scripts/library-sources.json` and list your songs. Each entry has an `id` (lowercase letters, digits and dashes), a `title`, a `genre` (`lofi`, `grooves` or `electronic`), a `path` and a `status` (`new` or `inMix`). A one-line description in English and Korean, a cover picture and three colours are optional; the example file shows how.
4. Build the library:

   ```bash
   .venv-audio/bin/python Scripts/build_library.py \
     --library "$HOME/Library/Application Support/Focus Music/Library" \
     --sources Scripts/library-sources.json
   ```

   It copies each song into the library, sets its loudness, finds its beat for the pulse and picks the part that repeats for 30 minutes. A running app picks up the new list within 10 seconds. For the dev build use `Focus Music Dev/Library`; with `--data-dir`, use `<that folder>/Library`.

`Scripts/clean_endings.py` and `Scripts/trim_song_end.py` cut a song short when the part after its loop has a gap or loses the beat.

### Checks

```bash
Scripts/check-app-logic.sh                                # records, day boundaries, playlist, shuffle, learning
FOCUS_AUDIO_CHECKS=2,3,12 Scripts/check-audio-engine.sh   # sound engine checks that need no audio files
```

The full `Scripts/check-audio-engine.sh` also plays songs from `Audio/TestFixtures/` (`electronic-a.wav`, `electronic-b.wav`, `grooves-a.wav` and two reference renders in `comparisons/`) and the three noise loops. Those files are not in the repository. Without them the run names each missing file, skips the checks that need it, and fails. Nothing is heard: the engine runs offline or muted.

### Make the .dmg

`Scripts/package-share.sh` makes the website build: it builds the app with your songs inside and Sparkle for updates, signs it with your Developer ID, notarizes and staples it, wraps it in a .dmg in `dist/share/`, and writes a signed update feed in `dist/share/updates/`. Before you run it:

1. Fill in `Scripts/share/share.env` (the lines marked CHANGE): your Developer ID identity, your notarytool profile, and the keychain account of your own Sparkle key. The scripts stop while these are placeholders.
2. Get Sparkle: run `Scripts/share/get-sparkle.sh`. It downloads the official Sparkle release from GitHub into `build/vendor/` and checks its SHA-256 against `share.env`.
3. Make your update key once: `build/vendor/Sparkle-2.10.1/bin/generate_keys --account <name>`. Put the account name in `SHARE_SPARKLE_ACCOUNT` and the public key it prints in `SHARE_SPARKLE_PUBLIC_KEY`, and back up the private key: without it, installed copies can't update any more.
4. For a build you share: use your own `SHARE_NAME`, `SHARE_BUNDLE_ID`, `SHARE_FEED_URL` and `SHARE_UPDATES_URL`, and replace the icon and everything drawn from its design. The ADHD Music name and icon are not licensed to you (see [ASSETS.md](ASSETS.md)):
   - `Scripts/share/AppIcon.icon` (`band.svg`, `wave.svg`, `icon.json`) and `Scripts/share/icon_glyph.py`, which writes the two SVGs
   - the menu bar glyph drawn by `MenuBarIcon` in `Sources/App/AppShell.swift`
   - the wave arrow that `Scripts/share/dmg_background.swift` draws in the dmg window (or skip the designed window: without `build/.venv-dmg` the script makes a plain one)
5. Build your song library (the script bundles it from `~/Library/Application Support/Focus Music/Library`) and set up `.venv-audio`.
6. Put your own `rain.flac`, `ocean.flac` and `stream.flac` in `Audio/Noise/LoopsShare/`. The script refuses to build without them; `--allow-missing-noise` passes through for a local test only.

Each release: raise `SHARE_BUILD` in `share.env` (never reuse one), set `SHARE_VERSION`, and run `Scripts/package-share.sh`. At the end it checks the feed and every file it lists with the public key, the way the app will, and prints what to put online: `appcast.xml` at `SHARE_FEED_URL`, and the new .dmg and its delta files under `SHARE_UPDATES_URL`. Keep the older .dmgs in `dist/share/updates/`: the next release's deltas are made from them.

`Scripts/share/update-test.sh` tries the whole update on your Mac first: it builds two test versions with their own app id, data folder, local feed and a throwaway key, runs the older one, and checks that it updates itself while idle and waits while music plays.

The comments at the top of each script cover the details (the Xcode notarization route, the optional designed dmg window).

### Where things are

| Path | What |
| --- | --- |
| `Sources/App/` | The menu bar app: player, Timer & Sound, Playlist, History, Settings, pausing by itself, updates (`Updates.swift`, website build only) |
| `Sources/Audio/` | The sound engine: 30-minute seamless play, crossfades between songs, the pulse on the beat, background sounds |
| `Tests/` | Logic and sound engine checks |
| `Scripts/` | Build, checks and the song library tools |
| `Scripts/share/` | The website build: app icon, dmg window, signing and update settings, update test |
| `Scripts/mas/` | The Mac App Store build: sandbox, privacy manifest, account setup |
| `site/` | The website, adhdmusic.app (HTML and images; the videos and the audio clip are not in the repository) |

## Credits

Rain, waves and stream in the released app are made from these CC0 recordings on Freesound. Thank you to the people who recorded them.

- Rain: "Rain on grass and leaves" by SamsterBirdies, https://freesound.org/people/SamsterBirdies/sounds/584268/
- Waves: "waves on shingle beach" by brick_on_de (the first 1:45), https://freesound.org/people/brick_on_de/sounds/274135/
- Stream: "Stream Wyre forest 8.1.14" by turbostream (the first 2:45), https://freesound.org/people/turbostream/sounds/220528/

All three are under CC0 1.0: https://creativecommons.org/publicdomain/zero/1.0/

The website build updates itself with [Sparkle](https://sparkle-project.org) (MIT License), which ships inside that build with its license.

## License

The code is under the MIT License (see [LICENSE](LICENSE)). The music, cover art, app icon, the images in `site/`, and the name and brand ADHD Music are not; see [ASSETS.md](ASSETS.md).

---

## 한국어

ADHD Music은 집중해서 일할 때 트는, 가사 없이 밋밋하게 반복되는 음악 앱이에요. Mac 메뉴 막대에서 돌아가는 무료 앱이고, ADHD가 있는 사람들을 위해 만들었어요.

**다운로드:** https://adhdmusic.app/download (무료, 약 460MB, macOS 26 이상, Apple 실리콘)

### 어떤 앱인가요

메뉴 막대에 있다가, 재생을 누르면 배경에 머무는 음악을 틀어 줘요. 재생하고 바로 일을 시작하면 돼요.

곡은 27곡이에요. Lo-fi 12곡, Grooves 8곡, Electronic 7곡이고, 곡마다 30분 동안 끊김 없이 이어서 나와요.

### 왜 집중에 좋은가요

- **말소리 없음.** 가사가 있으면 생각이 말로 끌려가요. 이 곡엔 말소리가 없어요.
- **튀는 순간 없음.** ADHD 뇌는 갑작스러운 소리에 더 크게 반응해요. 여기엔 튀어나오는 소리가 없어요.
- **멜로디 없는 반복.** 한 가지 패턴이 계속 돌아요. 따라갈 멜로디가 없어 배경에 머물러요.
- **박자에 맞춘 떨림.** 모든 곡에 박자에 맞춘 은은한 떨림이 들어 있어요. 세기는 직접 골라요.

### 할 수 있는 것

- **자동으로 멈춤.** 자리를 비우거나, 통화 중이거나, 헤드폰을 빼거나, 유튜브 영상처럼 다른 앱에서 소리가 나면 멈추고, 끝나면 다시 틀어요.
- **배경 소음.** 빗소리, 파도, 시냇물, 브라운·핑크·화이트 노이즈를 음악 밑에 깔 수 있어요.
- **타이머, 포모도로, 시간 제한 없음.**
- **오늘 집중한 시간**이 메뉴 막대에 보여요. 음악이 나오는 동안만 세요.
- **기록.** 주 띠, 하루 시간표, 할 일별 시간과 들은 음악, 월 보기가 있어요.
- **재생 목록.** 목록 하나를 네 가지로 정렬해요. 섞어 틀면 방금 들은 곡은 바로 다시 나오지 않고, 하트를 누른 곡은 더 자주 나와요. 한 곡만 계속 들을 수도 있어요.
- **넘긴 곡 학습.** 일찍 넘긴 곡은 덜 나와요.
- **키보드.** 스페이스바로 재생·멈춤을 하고, 단축키와 미디어 키도 돼요.
- **내 Mac 안에서만.** 계정도 분석도 없어요. 기록은 내 Mac에만 남아요.
- 영어와 한국어를 지원해요.

### 설치

1. .dmg 파일을 받아요: https://adhdmusic.app/download
2. 파일을 열고 ADHD Music을 응용 프로그램(Applications) 폴더로 끌어다 놓아요.
3. ADHD Music을 열면 메뉴 막대에 나타나요.
4. 처음 한 번 macOS가 '시스템 오디오 녹음'을 물어요. 허용하면 유튜브 영상이 나오는 동안 음악이 멈춰요. 아무것도 녹음하지 않아요.

macOS 26 이상, Apple 실리콘 Mac에서 돌아가요.

### 자동 업데이트

adhdmusic.app에서 받은 앱은 알아서 최신으로 바뀌어요. 하루에 한 번쯤 https://adhdmusic.app/appcast.xml 을 확인하고, 새 판이 있으면 뒤에서 조용히 받아(보통 작은 조각만 받아요) 서명을 확인한 다음, 패널이 닫혀 있고 15분 동안 음악이 나오지 않을 때나 앱을 끌 때 설치해요. 화면에 뜨는 건 없어요. 확인할 때 보내는 건 앱의 판 번호뿐이에요.

업데이트에는 [Sparkle](https://sparkle-project.org)을 써요. 직접 빌드한 앱은 스스로 업데이트하지 않아요(내 서명과 내 업데이트 목록으로 웹사이트판을 만들어 배포하는 경우는 빼고요).

### 소스에서 빌드하기

곡과 커버 그림은 이 저장소에 없어요([ASSETS.md](ASSETS.md)). 이 코드로 빌드한 앱은 곡을 직접 넣기 전까지 재생 목록이 비어 있어요.

필요한 것: macOS 26 이상(Apple 실리콘), Xcode 26 이상. Xcode를 활성 개발 도구로 정해 두세요: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`(Command Line Tools만 있으면 앱 아이콘을 만드는 `actool`이 없어요). 곡을 넣으려면 Python 3.9~3.12(macOS에 들어 있는 `/usr/bin/python3`이 3.9예요)와 ffmpeg(`brew install ffmpeg`)도 필요해요.

```bash
git clone https://github.com/lazydevz-inc/adhd-music.git
cd adhd-music
Scripts/build-app.sh --allow-missing-noise
open "dist/ADHD Music.app"
```

- `--allow-missing-noise`를 붙이면 빗소리·파도·시냇물 없이 빌드해요. 이 세 소리도 저장소에 없어서, 고르면 조용해요. 브라운·핑크·화이트 노이즈는 앱이 직접 만들어서 늘 나와요. 세 소리를 넣으려면 끊김 없이 반복되는 스테레오 FLAC 파일을 `Audio/Noise/LoopsShare/rain.flac`, `ocean.flac`, `stream.flac`에 두고(초당 48,000 샘플) 플래그 없이 빌드해요.
- Apple Development 인증서가 있으면 그걸로 서명하고, 없으면 ad hoc으로 서명해요. ad hoc이면 빌드할 때마다 '시스템 오디오 녹음'을 다시 물어요.
- 직접 빌드한 앱(`app.adhdmusic.local`)은 기록·하트·학습·곡 보관함을 `~/Library/Application Support/Focus Music/`에 둬서, 받은 앱(`ADHD Music` 폴더)과 섞이지 않아요. `--dev` 빌드는 `Focus Music Dev` 폴더를 따로 써요.
- 기록을 건드리지 않고 시험하려면 `--data-dir ~/adhd-music-test`처럼 다른 폴더를 줘서 실행해요. `--seed-demo`는 하루치 예시 기록을 넣어요.

**곡 넣기**

1. 한 번만 준비해요: `/usr/bin/python3 -m venv .venv-audio` 다음 `.venv-audio/bin/pip install -r Scripts/requirements-audio.txt`.
2. WAV나 FLAC 파일을 `Audio/Songs/`에 넣어요. `Audio/`는 git이 무시해요.
3. `Scripts/library-sources.example.json`을 `Scripts/library-sources.json`으로 복사하고 곡을 적어요. 곡마다 `id`(영어 소문자·숫자·대시), `title`, `genre`(`lofi`, `grooves`, `electronic`), `path`, `status`(`new` 또는 `inMix`)를 적어요. 한 줄 소개, 커버 그림, 색 세 가지는 넣어도 되고 안 넣어도 돼요.
4. 보관함을 만들어요:

   ```bash
   .venv-audio/bin/python Scripts/build_library.py \
     --library "$HOME/Library/Application Support/Focus Music/Library" \
     --sources Scripts/library-sources.json
   ```

   곡마다 음량을 맞추고, 떨림을 맞출 박자를 찾고, 30분 동안 반복할 구간을 골라요. 켜져 있는 앱은 10초 안에 새 목록을 읽어요.

**검사**: `Scripts/check-app-logic.sh`, 그리고 오디오 파일 없이 도는 소리 엔진 검사 `FOCUS_AUDIO_CHECKS=2,3,12 Scripts/check-audio-engine.sh`. 전체 소리 엔진 검사는 저장소에 없는 `Audio/TestFixtures/`의 곡과 배경 소음 파일이 있어야 다 통과해요. 소리는 나지 않아요.

**.dmg 만들기(웹사이트판)**: `Scripts/package-share.sh`가 내 곡을 넣고 Sparkle을 붙여 빌드하고, Developer ID로 서명·공증한 .dmg와 서명된 업데이트 목록을 `dist/share/`에 만들어요. 실행하기 전에:

1. `Scripts/share/share.env`에서 CHANGE 표시가 있는 줄을 내 것으로 바꿔요: Developer ID 서명, notarytool 프로필, 내 Sparkle 열쇠의 키체인 계정. 예시 값 그대로면 스크립트가 멈춰요.
2. `Scripts/share/get-sparkle.sh`를 실행해 Sparkle을 받아요. GitHub의 공식 배포본을 `build/vendor/`에 받고 SHA-256을 확인해요.
3. 업데이트 열쇠를 한 번 만들어요: `build/vendor/Sparkle-2.10.1/bin/generate_keys --account <이름>`. 계정 이름은 `SHARE_SPARKLE_ACCOUNT`에, 출력되는 공개 열쇠는 `SHARE_SPARKLE_PUBLIC_KEY`에 넣고, 비밀 열쇠는 꼭 백업해요. 잃으면 깔린 앱이 더는 업데이트를 못 받아요.
4. 남에게 나눠 줄 빌드라면 이름·앱 id·업데이트 주소를 내 것으로 바꾸고, 아이콘과 그 디자인으로 그린 것도 모두 바꿔요. ADHD Music이라는 이름과 아이콘은 라이선스에 들어 있지 않아요([ASSETS.md](ASSETS.md)).
5. 곡 보관함을 만들어 두고(스크립트가 `~/Library/Application Support/Focus Music/Library`에서 곡을 가져가요), 내 `rain.flac`, `ocean.flac`, `stream.flac`을 `Audio/Noise/LoopsShare/`에 넣어요.

새 판을 낼 때마다 `share.env`의 `SHARE_BUILD`를 올리고(다시 쓰지 않아요) `Scripts/package-share.sh`를 실행해요. 끝에 무엇을 어디에 올릴지 알려 줘요. `Scripts/share/update-test.sh`로 업데이트 전체를 내 Mac에서 먼저 시험할 수 있어요. 앱스토어판은 [Scripts/mas/README.md](Scripts/mas/README.md)를 보세요.

### 크레딧

배포하는 앱의 빗소리·파도·시냇물은 Freesound의 CC0 녹음으로 만들었어요. 녹음해 준 분들께 고마워요.

- 빗소리: "Rain on grass and leaves", SamsterBirdies, https://freesound.org/people/SamsterBirdies/sounds/584268/
- 파도: "waves on shingle beach", brick_on_de(앞 1분 45초), https://freesound.org/people/brick_on_de/sounds/274135/
- 시냇물: "Stream Wyre forest 8.1.14", turbostream(앞 2분 45초), https://freesound.org/people/turbostream/sounds/220528/

세 녹음 모두 CC0 1.0이에요: https://creativecommons.org/publicdomain/zero/1.0/

### 라이선스

코드는 MIT 라이선스예요([LICENSE](LICENSE)). 음악, 커버 그림, 앱 아이콘, `site/`의 그림, ADHD Music이라는 이름과 브랜드는 MIT 라이선스가 아니에요. [ASSETS.md](ASSETS.md)를 보세요.
