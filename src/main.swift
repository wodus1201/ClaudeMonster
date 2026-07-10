import Cocoa
import CoreText
import ServiceManagement

// ── Claude Monster ─────────────────────────────────────────────────────────
// Personal macOS menu-bar app showing your real Claude usage limits, using the
// same source the IDE extension does: GET /api/oauth/usage with the OAuth token
// Claude Code already stored in the macOS Keychain. No external deps.

// MARK: - Config

let API_URL = "https://api.anthropic.com/api/oauth/usage"
let OAUTH_BETA = "oauth-2025-04-20"
let KEYCHAIN_SERVICE = "Claude Code-credentials"
let REFRESH_SECONDS: TimeInterval = 240      // 4 min — gentle on the usage endpoint
let MAX_BACKOFF: TimeInterval = 1800         // cap backoff at 30 min
let PIXEL_FONT_NAME = "NeoDunggeunmo"

// Self-update: we poll the GitHub Releases API and swap the .app bundle in place.
// The release tag must be the version with a leading "v" (v1.1 ⇒ VERSION 1.1),
// and the release must carry a ClaudeMonster.zip asset. ./release.sh does both.
let REPO = "wodus1201/ClaudeMonster"
let RELEASES_API = "https://api.github.com/repos/\(REPO)/releases/latest"
let RELEASES_PAGE = "https://github.com/\(REPO)/releases/latest"
let UPDATE_CHECK_INTERVAL: TimeInterval = 6 * 3600   // once every 6 hours

/// This build's version, from Info.plist (injected by build.sh from ./VERSION).
let APP_VERSION = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

/// Sentinel error meaning "no OAuth token in the Keychain" — i.e. Claude Code
/// was never logged in on this Mac. It's the one failure the user can fix, so
/// the menu answers it with instructions instead of a bare error line.
let NO_TOKEN_ERROR = "로그인 토큰 없음"

// The app was called "ClaudeBattery" before 1.2. These two names are HISTORICAL
// — they identify what an older install left behind, not what we are now — so a
// future rename must not touch them or the cleanup below silently stops working.
let LEGACY_LAUNCH_AGENT_ID = "com.jay.ClaudeBattery"
let LEGACY_PROCESS_NAME = "ClaudeBattery"

// MARK: - Pixel font

/// Register the bundled NeoDunggeunmo pixel font so we can use it by name.
func registerPixelFont() {
    guard let url = Bundle.main.url(forResource: "neodgm", withExtension: "ttf") else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}

/// Pixel font at a given size, falling back to a monospaced system font.
func pixelFont(_ size: CGFloat) -> NSFont {
    NSFont(name: PIXEL_FONT_NAME, size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
}

// MARK: - Pokémon-style flavor lines (by remaining HP %)
// Tone grounded in Pokémon-Amie/포켓파를레 emotional status messages
// (e.g. "울상을 짓고", "울어버린 것 같다").

func flavorLine(remaining: Int) -> String {
    switch remaining {
    case 90...100: return "클로드가 기운차게 뛰어다닌다!"
    case 70...89:  return "클로드가 콧노래를 부른다."
    case 45...69:  return "클로드가 조금 지친 기색이다."
    case 25...44:  return "클로드가 헥헥거리기 시작했다."
    case 10...24:  return "클로드가 울상을 짓고 있다."
    case 1...9:    return "클로드가 곧 쓰러질 것 같다!"
    default:       return "클로드가 쓰러졌다!"
    }
}

/// Shown in the dialogue slot while rate-limited (429): the app is dozing.
let SLEEP_MESSAGE = "클로드가 졸고 있다. 깨우지 말자.."

// MARK: - Petting (sprite click) lines
// Tone borrowed from Pokémon-Amie affection messages. Keyed off the same Mood
// that drives the HP-bar color, so the line always matches what the bar shows:
// lively when healthy, needy when hurt, unresponsive when fainted.

func pettingLines(mood: Mood) -> [String] {
    switch mood {
    case .healthy: return [          // green bar
        "클로드가 기뻐서 빙글빙글 돈다!",
        "클로드가 몸을 부비부비 해온다!",
        "클로드가 폴짝폴짝 뛰어오른다!",
        "클로드가 활짝 웃으며 올려다본다!",
        "클로드는 무척 행복해 보인다!",
    ]
    case .tired: return [            // orange bar
        "클로드가 기분 좋은 듯 눈을 감는다.",
        "클로드가 살며시 다가와 앉는다.",
        "클로드가 꼬리를 살랑살랑 흔든다.",
        "클로드가 나른하게 웃어 보인다.",
    ]
    case .hurt: return [             // red bar
        "클로드가 힘없이 몸을 기대온다..",
        "클로드가 당신의 손을 꼭 잡는다..",
        "클로드가 조금 기운을 낸 것 같다.",
        "클로드가 애써 미소를 지어 보인다..",
    ]
    case .fainted: return [
        "클로드는 쓰러져서 반응이 없다..",
        "클로드를 포켓몬센터에 데려가자..",
    ]
    // .happy is the reaction itself, never the state we react from.
    case .happy: return pettingLines(mood: .healthy)
    }
}

/// How long a petting reaction stays on screen before the normal slot cycle resumes.
let PETTING_HOLD: TimeInterval = 3.0

/// Korean "time until the Pokémon Center" (i.e. until the limit resets).
func resetKorean(_ date: Date?) -> String {
    guard let date = date else { return "알 수 없음" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "곧 도착!" }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "\(d)일 \(h)시간" }
    if h > 0 { return "\(h)시간 \(m)분" }
    return "\(m)분"
}

/// Every string the dialogue slot might ever display — used to reserve a fixed
/// slot width so the widget never reflows when the text swaps or the clock ticks.
func allSlotStrings() -> [String] {
    var s = [90, 70, 45, 25, 10, 5, 0].map { flavorLine(remaining: $0) }
    // Sprite-click reactions share the same slot, so reserve room for them too.
    s += [Mood.healthy, .tired, .hurt, .fainted].flatMap { pettingLines(mood: $0) }
    s.append(SLEEP_MESSAGE)
    // Longest plausible countdown renderings.
    s += ["포켓몬센터까지 23시간 59분", "포켓몬센터까지 6일 23시간"]
    return s
}

// MARK: - Claude pixel sprite

enum Mood { case healthy, tired, hurt, fainted, happy }

func mood(remaining: Int) -> Mood {
    if remaining >= 50 { return .healthy }   // green
    if remaining >= 20 { return .tired }     // orange
    if remaining >= 1  { return .hurt }      // red
    return .fainted                          // 0
}

let spriteColors: [Character: NSColor] = [
    "B": NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1),  // Claude orange
    "D": NSColor(srgbRed: 0xA6/255, green: 0x47/255, blue: 0x2E/255, alpha: 1),  // dark outline
    "K": NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),              // near-black
    "W": NSColor.white,
    "T": NSColor(srgbRed: 0x4F/255, green: 0xA3/255, blue: 0xE3/255, alpha: 1),  // tear/sweat
    "M": NSColor(srgbRed: 0x5A/255, green: 0x22/255, blue: 0x22/255, alpha: 1),  // mouth
]

let spriteColorsFainted: [Character: NSColor] = [
    "B": NSColor(calibratedWhite: 0.72, alpha: 1),
    "D": NSColor(calibratedWhite: 0.45, alpha: 1),
    "K": NSColor(calibratedWhite: 0.15, alpha: 1),
    "W": NSColor.white,
    "T": NSColor(calibratedWhite: 0.70, alpha: 1),
    "M": NSColor(calibratedWhite: 0.30, alpha: 1),
]

// Official-style Clawd: 20 cols x 14 rows. The body/ears/arms/legs are constant;
// only the two eye rows (index 5,6) change per mood. Row 0 = top.
let clawdBase: [String] = [
    ".....DBBBBBBBBD.....",
    "....DBDBBBBBBDBD....",
    "..DBBBBBBBBBBBBBBD..",
    "..DBBBBBBBBBBBBBBD..",
    "..DBBBBBBBBBBBBBBD..",
    "..DBBBBBBBBBBBBBBD..",   // eyes row (5) — replaced per mood
    "..DBBBBBBBBBBBBBBD..",   // eyes row (6) — replaced per mood
    "DDBBBBBBBBBBBBBBBBDD",   // arms
    "DDBBBBBBBBBBBBBBBBDD",   // arms
    "..DBBBBBBBBBBBBBBD..",
    "..DBBBBBBBBBBBBBBD..",
    "..DBBBBBBBBBBBBBBD..",
    "...DB..BD..BD..BD...",
    "...DB..BD..BD..BD...",
]

func makeFace(_ eyeRow5: String, _ eyeRow6: String) -> [String] {
    var g = clawdBase
    g[5] = eyeRow5
    g[6] = eyeRow6
    return g
}

// Row 0 = top. Frames per mood; index 1 (if present) is a brief blink.
let spriteGrids: [Mood: [[String]]] = [
    // content: open eyes; blink: eyes closed
    .healthy: [
        makeFace("..DBBBKKBBBBKKBBBD..", "..DBBBKKBBBBKKBBBD.."),
        makeFace("..DBBBBBBBBBBBBBBD..", "..DBBBKKBBBBKKBBBD.."),
    ],
    // tired: half-lidded (single row) + sweat drop at top-right
    .tired: [
        makeFace("..DBBKKKBBBBKKKBBD..", "..DBBBKKBBBBKKBBBD.."),
        makeFace("..DBBBBBBBBBBBBBBD..", "..DBBKKKBBBBKKKBBD.."),
    ],
    // hurt: wide worried eyes + teardrop
    .hurt: [
        makeFace("..DBBBKKBBBBKKBBBD..", "..DBTTKKBBBBKKTTBD.."),
        makeFace("..DBBBBBBBBBBBBBBD..", "..DBTTKKBBBBKKTTBD.."),
    ],
    // fainted: X-shaped eyes
    .fainted: [
        makeFace("..DBBBBBBBBBBBBBBD..", "..DBBKKKBBBBKKKBBD.."),
    ],
    // happy (sprite clicked): upturned "^ ^" eyes. Single frame — no blink, so
    // the smile holds steady for the whole petting window.
    .happy: [
        makeFace("..DBBBBKBBBBKBBBBD..", "..DBBBKBKBBKBKBBBD.."),
    ],
]

/// Draw a pixel grid with crisp (non-antialiased) cells; row 0 is the top.
func drawSprite(_ grid: [String], origin: NSPoint, cell: CGFloat, colors: [Character: NSColor] = spriteColors) {
    guard let ctx = NSGraphicsContext.current else { return }
    ctx.saveGraphicsState()
    ctx.shouldAntialias = false
    let rows = grid.count
    for (r, line) in grid.enumerated() {
        for (c, ch) in line.enumerated() {
            guard let color = colors[ch] else { continue }
            color.setFill()
            let x = origin.x + CGFloat(c) * cell
            let y = origin.y + CGFloat(rows - 1 - r) * cell   // flip vertically
            NSRect(x: x, y: y, width: cell, height: cell).fill()
        }
    }
    ctx.restoreGraphicsState()
}

// MARK: - Model

struct Limit {
    let kind: String        // "session", "weekly_all", "weekly_scoped"
    let percent: Int        // 0..100 used
    let resetsAt: Date?
    let scopeName: String?  // e.g. "Fable"
    let isActive: Bool
}

struct UsageResult {
    var limits: [Limit] = []
    var error: String? = nil
    var rateLimited: Bool = false   // HTTP 429 from the usage endpoint
}

// MARK: - Token

/// Read the OAuth access token from the macOS Keychain (falls back to the
/// credentials file), mirroring how Claude Code stores it.
func readAccessToken() -> String? {
    // 1) Keychain
    let task = Process()
    task.launchPath = "/usr/bin/security"
    task.arguments = ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let raw = String(data: data, encoding: .utf8),
       let token = tokenFromCredentialsJSON(raw) {
        return token
    }
    // 2) File fallback
    let home = FileManager.default.homeDirectoryForCurrentUser
    let credURL = home.appendingPathComponent(".claude/.credentials.json")
    if let raw = try? String(contentsOf: credURL, encoding: .utf8),
       let token = tokenFromCredentialsJSON(raw) {
        return token
    }
    return nil
}

func tokenFromCredentialsJSON(_ raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty else { return nil }
    return token
}

// MARK: - Fetch

func fetchUsage(completion: @escaping (UsageResult) -> Void) {
    guard let token = readAccessToken() else {
        completion(UsageResult(error: NO_TOKEN_ERROR))
        return
    }
    guard let url = URL(string: API_URL) else {
        completion(UsageResult(error: "URL 오류")); return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(OAUTH_BETA, forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 10

    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err = err { completion(UsageResult(error: err.localizedDescription)); return }
        guard let http = resp as? HTTPURLResponse else {
            completion(UsageResult(error: "응답 없음")); return
        }
        if http.statusCode == 429 {
            completion(UsageResult(error: "요청이 많아 잠시 대기 중", rateLimited: true)); return
        }
        guard http.statusCode == 200, let data = data else {
            completion(UsageResult(error: "HTTP \(http.statusCode)")); return
        }
        completion(parseUsage(data))
    }.resume()
}

func parseUsage(_ data: Data) -> UsageResult {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawLimits = obj["limits"] as? [[String: Any]] else {
        return UsageResult(error: "파싱 실패")
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoNoFrac = ISO8601DateFormatter()
    isoNoFrac.formatOptions = [.withInternetDateTime]

    var result = UsageResult()
    for l in rawLimits {
        let kind = l["kind"] as? String ?? "?"
        let percent = (l["percent"] as? NSNumber)?.intValue ?? 0
        let isActive = l["is_active"] as? Bool ?? false
        var resetsAt: Date? = nil
        if let s = l["resets_at"] as? String {
            resetsAt = iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        var scopeName: String? = nil
        if let scope = l["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any],
           let name = model["display_name"] as? String {
            scopeName = name
        }
        result.limits.append(Limit(kind: kind, percent: percent,
                                    resetsAt: resetsAt, scopeName: scopeName,
                                    isActive: isActive))
    }
    return result
}

// MARK: - Self-update

/// Compare dotted versions numerically: "1.10" is newer than "1.9",
/// which a plain string compare would get backwards.
func isNewer(_ candidate: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

struct Release {
    let version: String   // tag without the leading "v"
    let zipURL: URL
}

/// Ask GitHub for the latest release. Returns nil on any failure — a missing
/// network or a rate-limited API must never disturb the widget.
func fetchLatestRelease(completion: @escaping (Release?) -> Void) {
    guard let url = URL(string: RELEASES_API) else { completion(nil); return }
    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 10

    URLSession.shared.dataTask(with: req) { data, resp, _ in
        guard let data = data,
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]]
        else { completion(nil); return }

        // The .app is shipped as a zip asset; without it there's nothing to install.
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let urlStr = zip?["browser_download_url"] as? String,
              let zipURL = URL(string: urlStr)
        else { completion(nil); return }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        completion(Release(version: version, zipURL: zipURL))
    }.resume()
}

enum UpdateError: LocalizedError {
    case download(String), unpack, noBundle, notWritable(String), devBuild
    var errorDescription: String? {
        switch self {
        case .download(let m): return "다운로드 실패: \(m)"
        case .unpack:          return "압축 해제 실패"
        case .noBundle:        return "새 앱을 찾을 수 없습니다"
        case .notWritable(let p): return "쓰기 권한 없음: \(p)"
        case .devBuild:
            return "개발 빌드(build/)는 자동 업데이트를 지원하지 않습니다.\n"
                 + "소스에서는 git pull && ./build.sh 를 사용하세요."
        }
    }
}

/// Download the release zip, unpack it, then hand off to a detached script that
/// swaps the bundle and relaunches. We cannot overwrite our own bundle while
/// running, so the script waits for this process to exit first.
func installUpdate(_ release: Release, completion: @escaping (Error?) -> Void) {
    // The running bundle may be reached via the /Applications symlink that
    // install.sh creates; resolve it so we replace the real directory.
    let installedApp = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let parent = installedApp.deletingLastPathComponent()

    // Resolving that symlink can land us inside the source checkout's build/
    // directory. Overwriting a build artifact with a release zip would just
    // confuse the next ./build.sh, so refuse and point at the git workflow.
    guard parent.lastPathComponent != "build" else {
        completion(UpdateError.devBuild); return
    }
    guard FileManager.default.isWritableFile(atPath: parent.path) else {
        completion(UpdateError.notWritable(parent.path)); return
    }

    URLSession.shared.downloadTask(with: release.zipURL) { tmp, _, err in
        if let err = err { completion(UpdateError.download(err.localizedDescription)); return }
        guard let tmp = tmp else { completion(UpdateError.download("빈 응답")); return }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ClaudeMonsterUpdate-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: tmp, to: zip)

            // ditto preserves the bundle's symlinks and signature layout; unzip does not.
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { completion(UpdateError.unpack); return }

            // Find the .app the archive contains (name may differ from ours).
            let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "app" }
            guard let newApp = newApp else { completion(UpdateError.noBundle); return }

            try writeAndRunSwapScript(newApp: newApp, installedApp: installedApp, work: work)
            completion(nil)   // caller quits; the script takes over from here
        } catch {
            completion(error)
        }
    }.resume()
}

/// Write a detached script that waits for us to quit, swaps the bundle, and
/// relaunches. Detaching matters: it must outlive the process it replaces.
private func writeAndRunSwapScript(newApp: URL, installedApp: URL, work: URL) throws {
    let script = work.appendingPathComponent("swap.sh")
    // Wait on *our* process name rather than a hardcoded one, so a future
    // rename can't leave the script watching for a process that never exits.
    let proc = ProcessInfo.processInfo.processName
    let body = """
    #!/bin/bash
    # Wait (up to ~10s) for the running app to exit before touching its bundle.
    for _ in $(seq 1 100); do
      pgrep -x \(proc) >/dev/null || break
      sleep 0.1
    done
    pkill -x \(proc) 2>/dev/null || true
    sleep 0.3

    # Keep the old bundle until the new one is in place, so a failure is recoverable.
    BACKUP="\(installedApp.path).bak"
    rm -rf "$BACKUP"
    mv "\(installedApp.path)" "$BACKUP" 2>/dev/null || true
    if ! mv "\(newApp.path)" "\(installedApp.path)"; then
      mv "$BACKUP" "\(installedApp.path)" 2>/dev/null || true   # roll back
      rm -rf "\(work.path)"
      exit 1
    fi
    rm -rf "$BACKUP"

    # Re-sign ad-hoc: the zip round-trip and mv can invalidate the signature.
    codesign --force --sign - "\(installedApp.path)" 2>/dev/null || true
    xattr -dr com.apple.quarantine "\(installedApp.path)" 2>/dev/null || true

    open "\(installedApp.path)"
    rm -rf "\(work.path)"
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path]
    try p.run()   // detached: we exit right after, it keeps going
}

// MARK: - Presentation helpers

func label(for l: Limit) -> String {
    switch l.kind {
    case "session":       return "세션 (5시간)"
    case "weekly_all":    return "주간 (7일)"
    case "weekly_scoped": return "주간 \(l.scopeName ?? "")".trimmingCharacters(in: .whitespaces)
    default:              return l.kind
    }
}

/// Color by remaining headroom (traffic light).
func color(remaining frac: Double) -> NSColor {
    if frac >= 0.5 { return NSColor.systemGreen }
    if frac >= 0.2 { return NSColor.systemOrange }
    return NSColor.systemRed
}

/// Compact "resets in" string, e.g. "1h 47m", "3d 4h".
func resetIn(_ date: Date?) -> String {
    guard let date = date else { return "—" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "곧" }
    let d = secs / 86400
    let h = (secs % 86400) / 3600
    let m = (secs % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// 10-segment battery bar filled by remaining fraction (used in the menu).
func batteryBar(remaining frac: Double) -> String {
    let n = max(0, min(10, Int(round(frac * 10))))
    return String(repeating: "█", count: n) + String(repeating: "▁", count: 10 - n)
}

/// Pokémon-style HP bar enclosed in end caps, e.g. "▕████▁▁▁▁▁▏".
func pokemonHPBar(remaining frac: Double) -> String {
    let segments = 9
    let n = max(0, min(segments, Int(round(frac * Double(segments)))))
    let fill = String(repeating: "█", count: n)
    let empty = String(repeating: "▁", count: segments - n)
    return "▕\(fill)\(empty)▏"
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var last: UsageResult = UsageResult()
    var backoff: TimeInterval = 0   // grows on 429, resets on success
    var sleeping = false            // rate-limited (429): show dozing widget
    var isMocking = false           // UI-testing mode: never schedule a real fetch

    // Animation + live-render state
    var animTimer: Timer?
    var animTick: Int = 0
    var cycleStart = Date()          // anchors the text-slot swap cycle
    var driverUsed: Int? = nil       // used% of the tracked limit
    var driverResets: Date? = nil
    var lastLimits: [Limit] = []     // limits from the latest successful fetch
    // Which limit the widget tracks. Default = 5-hour session; user can switch
    // from the click menu, and the choice persists across restarts.
    var selectedKind: String = UserDefaults.standard.string(forKey: "selectedKind") ?? "session"
    // Compact mode: hides "Lv--" and shrinks the dialogue slot, so the widget
    // fits menu bars with limited space (e.g. MacBook Pro w/ many other icons)
    // instead of being pushed into the ">>" overflow. Default ON; togglable
    // from the click menu; persists across restarts.
    var compact: Bool = UserDefaults.standard.object(forKey: "compact") as? Bool ?? true
    var hasData = false
    var lastSignature = ""

    // Sprite-click ("petting") interaction. The status item has no attached menu
    // — the button action routes clicks by x-position — so we stash the menu the
    // button should pop up when the click lands outside the sprite.
    var currentMenu: NSMenu?
    var pettingUntil: Date?          // non-nil while the happy face + line show
    var pettingLine: String = ""
    var lastPettingLine: String = "" // avoid repeating a line back-to-back
    /// Sprite hit box in button coordinates, recorded at draw time.
    var spriteHitMaxX: CGFloat = 0

    // Self-update state
    var updateTimer: Timer?
    var availableUpdate: Release?    // non-nil once a newer release is seen
    var isUpdating = false           // guards against a double-click on 업데이트

    // Text-slot timing (seconds)
    let TIME_HOLD = 5.0             // how long the reset-countdown shows
    let FLAVOR_HOLD = 5.0            // how long the flavor line shows
    let CROSSFADE = 0.45            // swap transition duration

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerPixelFont()

        // Debug: CLAUDEMONSTER_DUMP=<path> renders sample frames and exits.
        if let dump = ProcessInfo.processInfo.environment["CLAUDEMONSTER_DUMP"] {
            dumpSamples(to: dump); exit(0)
        }
        // Build hook: CLAUDEMONSTER_ICON=<path> renders the 1024px app icon and exits.
        // make-icon.sh calls this, so the icon always matches the live sprite.
        if let icon = ProcessInfo.processInfo.environment["CLAUDEMONSTER_ICON"] {
            writeIconPNG(to: icon); exit(0)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // No statusItem.menu: we handle clicks ourselves so a click on the sprite
        // can pet Claude instead of opening the menu. See buttonClicked().
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(buttonClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setTitle(text: " 클로드 …", color: .secondaryLabelColor)
        // ~12fps animation loop; renderNow() is a no-op cheap-skip when nothing changed.
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.animTick += 1
            self?.renderNow()
        }

        // UI testing without hitting the network at all: CLAUDEMONSTER_MOCK=1
        // feeds fake usage data straight in and never calls fetchUsage/refresh.
        // Optional CLAUDEMONSTER_MOCK_PERCENT=NN overrides the session used%.
        if ProcessInfo.processInfo.environment["CLAUDEMONSTER_MOCK"] != nil {
            isMocking = true
            applyMock()
            return
        }
        migrateLegacyPreferences()
        retireLegacyInstall()
        refresh()
        scheduleUpdateChecks()

        // After the widget is actually on screen, so "메뉴바에 나타났습니다" is true.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.showWelcomeIfFirstRun()
        }
    }

    // MARK: - Self-update

    /// Check shortly after launch, then every UPDATE_CHECK_INTERVAL.
    func scheduleUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdate(userInitiated: false)
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: UPDATE_CHECK_INTERVAL,
                                           repeats: true) { [weak self] _ in
            self?.checkForUpdate(userInitiated: false)
        }
    }

    /// A background check only annotates the menu; a user-initiated one always
    /// reports back, including "you're already up to date".
    func checkForUpdate(userInitiated: Bool) {
        fetchLatestRelease { [weak self] release in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newer = release.map { isNewer($0.version, than: APP_VERSION) } ?? false
                self.availableUpdate = newer ? release : nil
                self.rebuildMenu()

                guard userInitiated else { return }
                if release == nil {
                    self.alert("업데이트 확인 실패", "네트워크 상태를 확인해 주세요.")
                } else if !newer {
                    self.alert("최신 버전입니다", "현재 버전 \(APP_VERSION)")
                }
                // If newer, the menu now shows the update item — no popup needed.
            }
        }
    }

    /// Menu action: download + swap + relaunch, with a confirmation first.
    @objc func installUpdateNow() {
        guard let release = availableUpdate, !isUpdating else { return }

        let a = NSAlert()
        a.messageText = "새 버전 \(release.version) 설치"
        a.informativeText = "다운로드 후 앱이 자동으로 재시작됩니다."
        a.addButton(withTitle: "설치")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        isUpdating = true
        rebuildMenu()
        installUpdate(release) { [weak self] err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.isUpdating = false
                    self.rebuildMenu()
                    self.alert("업데이트 실패", err.localizedDescription)
                } else {
                    // The swap script is waiting for us to exit.
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Menu action: user asked to check right now.
    @objc func checkForUpdateNow() { checkForUpdate(userInitiated: true) }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - First-run onboarding

    /// The widget lives only in the menu bar, so a first-time user gets no signal
    /// that anything launched — and no hint that the two things it needs (a Claude
    /// Code login, and auto-start) are opt-in. Say so once, then never again.
    func showWelcomeIfFirstRun() {
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let a = NSAlert()
        a.messageText = "Claude Monster에 오신 걸 환영합니다!"
        a.informativeText = """
            메뉴바 오른쪽에 클로드가 나타났습니다. 남은 사용 한도를 HP로 보여주고, \
            클로드를 클릭하면 쓰다듬을 수 있어요.

            시작하려면 이 맥에서 Claude Code에 로그인돼 있어야 합니다. \
            (터미널에서 claude 를 실행해 로그인하세요.)

            로그인이 돼 있다면 곧 Keychain 접근을 물어봅니다 — "항상 허용"을 눌러주세요.
            """
        a.addButton(withTitle: "로그인 시 자동 시작 켜기")
        a.addButton(withTitle: "나중에")
        NSApp.activate(ignoringOtherApps: true)

        if a.runModal() == .alertFirstButtonReturn, !launchAtLogin {
            do { try SMAppService.mainApp.register() }
            catch { alert("자동 시작 설정 실패", error.localizedDescription) }
            rebuildMenu()
        }
    }

    /// Menu action: shown when the Keychain has no Claude Code token.
    @objc func showLoginHelp() {
        let a = NSAlert()
        a.messageText = "Claude Code에 로그인하세요"
        a.informativeText = """
            이 위젯은 Claude Code가 Keychain에 저장해 둔 로그인 토큰을 읽어 \
            사용 한도를 가져옵니다. 토큰을 외부로 보내지 않습니다.

            1. 터미널을 엽니다
            2. claude 를 실행하고 안내에 따라 로그인합니다
            3. 이 메뉴에서 "다시 시도"를 누릅니다

            Claude Code가 설치돼 있지 않다면 claude.com/claude-code 를 참고하세요.
            """
        a.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: - Launch at login

    /// Whether macOS currently launches us at login (SMAppService, macOS 13+).
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() }
            else             { try SMAppService.mainApp.register() }
        } catch {
            alert("자동 시작 설정 실패", error.localizedDescription)
        }
        rebuildMenu()
    }

    /// UserDefaults are keyed by bundle ID, so the 1.2 rename orphaned the old
    /// app's preferences. Carry them over once rather than silently resetting
    /// the user's compact-mode and tracked-limit choices.
    func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        let key = "didMigrateLegacyPrefs"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        guard let old = UserDefaults(suiteName: LEGACY_LAUNCH_AGENT_ID) else { return }
        if let kind = old.string(forKey: "selectedKind") {
            defaults.set(kind, forKey: "selectedKind")
            selectedKind = kind
        }
        if let compactPref = old.object(forKey: "compact") as? Bool {
            defaults.set(compactPref, forKey: "compact")
            compact = compactPref
        }
    }

    /// Retire what a pre-1.2 "ClaudeBattery" install left behind: a LaunchAgent
    /// that starts the old binary, and possibly that binary still running. Both
    /// would sit alongside us — the agent fights SMAppService, and the old
    /// process puts a second widget in the menu bar.
    func retireLegacyInstall() {
        // Kill a still-running old build first; it has a different executable
        // name, so nothing else would ever reap it.
        if Bundle.main.executableURL?.lastPathComponent != LEGACY_PROCESS_NAME {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-x", LEGACY_PROCESS_NAME]
            try? kill.run()
            kill.waitUntilExit()
        }

        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(LEGACY_LAUNCH_AGENT_ID).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }

        let uid = getuid()
        let boot = Process()
        boot.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        boot.arguments = ["bootout", "gui/\(uid)/\(LEGACY_LAUNCH_AGENT_ID)"]
        try? boot.run()
        boot.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)

        // The plist existed, so auto-start was wanted. Re-express that through
        // SMAppService, which the menu toggle now owns. Only meaningful for an
        // installed bundle; a build/ copy would register the wrong path.
        let parent = Bundle.main.bundleURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().lastPathComponent
        if parent != "build", !launchAtLogin {
            try? SMAppService.mainApp.register()
        }
    }

    /// Feeds fixture data through the exact same `apply()` path real data uses,
    /// so the live menu-bar widget, animations, and click-to-switch menu all
    /// work normally — with zero network calls (apply() skips scheduleNext()
    /// while isMocking, so no timer ever fires a real fetchUsage()).
    func applyMock() {
        let env = ProcessInfo.processInfo.environment
        let sessionPct = Int(env["CLAUDEMONSTER_MOCK_PERCENT"] ?? "") ?? 41
        let now = Date()
        var mock = UsageResult()
        mock.limits = [
            Limit(kind: "session", percent: sessionPct,
                  resetsAt: now.addingTimeInterval(3600 * 2 + 60 * 13), scopeName: nil, isActive: false),
            Limit(kind: "weekly_all", percent: 55,
                  resetsAt: now.addingTimeInterval(3600 * 24 * 3), scopeName: nil, isActive: true),
            Limit(kind: "weekly_scoped", percent: 10,
                  resetsAt: now.addingTimeInterval(3600 * 24 * 3), scopeName: "Fable", isActive: false),
        ]
        apply(mock)
        // No real fetch loop is running, so nothing will call apply() again —
        // that's the point: no more network calls while you eyeball the UI.
    }

    /// Self-scheduling loop: normal cadence, but back off exponentially on 429
    /// so we never hammer the usage endpoint into a longer block.
    func scheduleNext() {
        let delay: TimeInterval
        if backoff > 0 {
            delay = min(backoff, MAX_BACKOFF)
        } else {
            delay = REFRESH_SECONDS
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    func setTitle(text: String, color: NSColor) {
        statusItem.button?.image = nil          // clear any drawn image
        let attr = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.foregroundColor, value: color, range: range)
        attr.addAttribute(.font,
                          value: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                          range: range)
        statusItem.button?.attributedTitle = attr
    }

    /// Decide what the dialogue slot shows: the reset countdown by default,
    /// briefly swapping to a flavor line, with a crossfade at each boundary.
    /// Returns (incoming, outgoing?, alpha 0..1 for incoming).
    func slotTexts(elapsed: TimeInterval, remaining: Int) -> (String, String?, CGFloat) {
        let timeText = "포켓몬센터까지 " + resetKorean(driverResets)
        let flavorText = flavorLine(remaining: remaining)
        let period = TIME_HOLD + FLAVOR_HOLD
        let ph = elapsed.truncatingRemainder(dividingBy: period)

        if ph < CROSSFADE {                                   // boundary → time
            return (timeText, flavorText, CGFloat(ph / CROSSFADE))
        } else if ph >= TIME_HOLD && ph < TIME_HOLD + CROSSFADE {  // boundary → flavor
            return (flavorText, timeText, CGFloat((ph - TIME_HOLD) / CROSSFADE))
        } else if ph < TIME_HOLD {
            return (timeText, nil, 1)
        } else {
            return (flavorText, nil, 1)
        }
    }

    /// Called ~12fps by the animation timer. Cheap-skips when nothing visible
    /// changed, so idle CPU stays near zero.
    func renderNow() {
        // Render whenever we have data OR we're dozing (even with no data yet).
        guard hasData || sleeping else { return }
        // Placeholder HP when we're dozing without ever having fetched data.
        let hpUnknown = (driverUsed == nil)
        let used = driverUsed ?? 0
        let remaining = max(0, min(100, 100 - used))

        let isFainted = !hpUnknown && remaining == 0

        // Petting expires on its own; clear it so the normal cycle resumes.
        if let until = pettingUntil, Date() >= until { pettingUntil = nil }
        let petting = pettingUntil != nil

        let bob = isFainted ? 0 : (animTick / 6) % 2
        let phase = animTick % 24
        var blink = isFainted ? false : (phase == 0 || phase == 1)

        let primary: String, secondary: String?, alpha: CGFloat
        if sleeping {
            // Dozing: closed eyes, no swap — just the sleep line.
            blink = true
            primary = SLEEP_MESSAGE; secondary = nil; alpha = 1
        } else if petting {
            // Petting: hold the reaction line steady, and never blink away the smile.
            blink = false
            primary = pettingLine; secondary = nil; alpha = 1
        } else {
            let elapsed = Date().timeIntervalSince(cycleStart)
            (primary, secondary, alpha) = slotTexts(elapsed: elapsed, remaining: remaining)
        }

        let sig = "\(used)|\(hpUnknown)|\(bob)|\(blink)|sleep=\(sleeping)|pet=\(petting)|\(compact)|\(primary)|\(secondary ?? "")|\(Int(alpha * 12))"
        if sig == lastSignature { return }
        lastSignature = sig

        let img = buildImage(used: used, remaining: remaining, bob: CGFloat(bob),
                             blink: blink, primary: primary, secondary: secondary, alpha: alpha,
                             sleeping: sleeping, hpUnknown: hpUnknown, compact: compact,
                             petting: petting)
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageOnly
    }

    func buildImage(used: Int, remaining: Int, bob: CGFloat, blink: Bool,
                    primary: String, secondary: String?, alpha: CGFloat,
                    sleeping: Bool = false, hpUnknown: Bool = false, compact: Bool = false,
                    petting: Bool = false) -> NSImage {
        // When HP is unknown (dozing before any data), the gauge is empty gray.
        let frac: CGFloat = hpUnknown ? 1 : CGFloat(remaining) / 100.0
        // Gauge turns gray while dozing.
        let hpColor = sleeping ? NSColor.systemGray : color(remaining: Double(frac))
        let black = NSColor.black

        let name = "클로드"
        let lv = hpUnknown ? ":Lv--" : ":Lv\(used)"
        let hpLabel = "HP:"
        let hpText = hpUnknown ? "--/100" : "\(remaining)/100"

        let nameAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(15), .foregroundColor: black]
        let lvAttr: [NSAttributedString.Key: Any]   = [.font: pixelFont(12), .foregroundColor: black]
        let hpTextAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(13), .foregroundColor: black]
        let hpLabelAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(10), .foregroundColor: NSColor.systemYellow]
        // Compact mode shrinks the dialogue-slot font so long sentences take less room.
        let slotFont = pixelFont(compact ? 9 : 12)

        let nameSize = (name as NSString).size(withAttributes: nameAttr)
        // Compact mode hides "Lv--" entirely (zero width) to save space.
        let lvSize = compact ? .zero : (lv as NSString).size(withAttributes: lvAttr)
        let hpTextSize = (hpText as NSString).size(withAttributes: hpTextAttr)
        let hpLabelSize = (hpLabel as NSString).size(withAttributes: hpLabelAttr)

        // Fixed slot width = widest string the slot can EVER show, so the whole
        // widget never reflows when text swaps or the countdown ticks. Text is
        // centered within this reserved area.
        let slotAttr: [NSAttributedString.Key: Any] = [.font: slotFont, .foregroundColor: black]
        var slotStrings = allSlotStrings()
        if sleeping { slotStrings.append(SLEEP_MESSAGE) }   // reserve room for the sleep line
        let slotW = ceil(slotStrings.map { ($0 as NSString).size(withAttributes: slotAttr).width }.max() ?? 120)

        // Sprite geometry
        let spriteCols: CGFloat = 20
        let spriteRows: CGFloat = 14
        let cell: CGFloat = 1.28
        let spriteW = spriteCols * cell
        let spriteH = spriteRows * cell

        let hpUnitW = hpLabelSize.width + 8 + 54     // label part + gauge part
        let gaugePartW: CGFloat = 54
        let unitH: CGFloat = 13
        let padX: CGFloat = 7
        let gap: CGFloat = 5
        let spriteNameGap: CGFloat = 7   // 스프라이트 ↔ 이름 간격 (이 숫자를 키우면 더 벌어짐)
        let flavorGap: CGFloat = 10
        let height = NSStatusBar.system.thickness

        let lvBlockW = compact ? 0 : lvSize.width + gap   // Lv text + its trailing gap, omitted when compact
        let contentW = spriteW + spriteNameGap + nameSize.width + gap + lvBlockW
            + hpUnitW + gap + hpTextSize.width + flavorGap + slotW
        let totalW = ceil(contentW + padX * 2)
        // Sprite occupies [padX, padX + spriteW] horizontally; remember its right
        // edge so buttonClicked() can tell a pet from a menu click.
        spriteHitMaxX = padX + spriteW

        let img = NSImage(size: NSSize(width: totalW, height: height), flipped: false) { rect in
            // Off-white rounded background pill.
            NSColor(white: 0.90, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 5, yRadius: 5).fill()

            let midY = rect.midY
            var x = padX

            // Sprite (left of the name), with a subtle vertical bob.
            // Unknown HP (dozing pre-data) uses the healthy face so blink = closed eyes.
            // Petting smiles — unless Claude has fainted, who stays fainted.
            var mood = hpUnknown ? .healthy : mood(remaining: remaining)
            if petting && mood != .fainted { mood = .happy }
            let frames = spriteGrids[mood] ?? spriteGrids[.healthy]!
            let grid = (blink && frames.count > 1) ? frames[1] : frames[0]
            let spriteOrigin = NSPoint(x: x, y: midY - spriteH / 2 + bob)
            let colors: [Character: NSColor] = remaining == 0 ? spriteColorsFainted : spriteColors
            drawSprite(grid, origin: spriteOrigin, cell: cell, colors: colors)
            x += spriteW + spriteNameGap   // 스프라이트 ↔ 이름 간격

            func drawText(_ s: String, _ attrs: [NSAttributedString.Key: Any], _ sz: NSSize) {
                (s as NSString).draw(at: NSPoint(x: x, y: midY - sz.height / 2), withAttributes: attrs)
                x += sz.width
            }

            drawText(name, nameAttr, nameSize); x += gap
            if !compact { drawText(lv, lvAttr, lvSize); x += gap }   // "Lv--" hidden in compact mode

            // Fused HP unit: single rounded pill, black "HP" cap + white gauge; only inner fill is colored.
            let unit = NSRect(x: x, y: midY - unitH / 2, width: hpUnitW, height: unitH)
            let labelW = hpUnitW - gaugePartW
            let unitPath = NSBezierPath(roundedRect: unit, xRadius: 3, yRadius: 3)
            NSGraphicsContext.current?.saveGraphicsState()
            unitPath.setClip()
            black.setFill(); NSRect(x: unit.minX, y: unit.minY, width: labelW, height: unitH).fill()
            NSColor.white.setFill(); NSRect(x: unit.minX + labelW, y: unit.minY, width: gaugePartW, height: unitH).fill()
            let innerInset: CGFloat = 3
            let innerFull = gaugePartW - innerInset
            if frac > 0 {
                hpColor.setFill()
                NSRect(x: unit.minX + labelW, y: unit.minY + innerInset,
                       width: innerFull * frac, height: unitH - innerInset * 2).fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
            black.setStroke(); unitPath.lineWidth = 1.5; unitPath.stroke()
            // divider + HP label
            black.setStroke()
            let div = NSBezierPath()
            div.move(to: NSPoint(x: unit.minX + labelW, y: unit.minY))
            div.line(to: NSPoint(x: unit.minX + labelW, y: unit.maxY))
            div.lineWidth = 1; div.stroke()
            (hpLabel as NSString).draw(
                at: NSPoint(x: unit.minX + (labelW - hpLabelSize.width) / 2, y: midY - hpLabelSize.height / 2),
                withAttributes: hpLabelAttr)
            x += hpUnitW + gap

            drawText(hpText, hpTextAttr, hpTextSize); x += flavorGap

            // Dialogue slot: fixed width, text centered, crossfade + vertical slide.
            let slotX = x
            func drawSlot(_ text: String, _ a: CGFloat, slideUp: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: slotFont, .foregroundColor: black.withAlphaComponent(max(0, min(1, a)))]
                let sz = (text as NSString).size(withAttributes: attrs)
                let cx = slotX + (slotW - sz.width) / 2   // center within reserved slot
                (text as NSString).draw(at: NSPoint(x: cx, y: midY - sz.height / 2 + slideUp), withAttributes: attrs)
            }
            if let secondary = secondary {
                drawSlot(secondary, 1 - alpha, slideUp: alpha * 4)        // outgoing rises & fades
                drawSlot(primary, alpha, slideUp: -(1 - alpha) * 4)      // incoming rises into place
            } else {
                drawSlot(primary, 1, slideUp: 0)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    func refresh() {
        fetchUsage { [weak self] result in
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    func apply(_ result: UsageResult) {
        last = result

        // Backoff bookkeeping, then schedule the next fetch — skipped entirely
        // in mock mode so UI testing never triggers a real network call.
        if !isMocking {
            if result.rateLimited {
                backoff = backoff == 0 ? REFRESH_SECONDS : min(backoff * 2, MAX_BACKOFF)
            } else if result.error == nil {
                backoff = 0   // success clears any backoff
            }
            scheduleNext()
        }

        if result.rateLimited {
            // Show the dozing widget in ALL cases — with prior data (gray bar at last
            // HP) or without (placeholder --/100). Never fall back to plain text.
            rebuildMenu()
            sleeping = true
            lastSignature = ""
            renderNow()
            return
        }
        sleeping = false

        if result.error != nil {
            hasData = false
            setTitle(text: " C ⚠", color: .systemRed)
            rebuildMenu()
            return
        }

        lastLimits = result.limits
        updateDriver(resetCycle: false)
        rebuildMenu()
    }

    /// Point the widget at the currently selected limit (default: 5-hour session).
    func updateDriver(resetCycle: Bool) {
        let driver = lastLimits.first(where: { $0.kind == selectedKind })
            ?? lastLimits.first(where: { $0.kind == "session" })
            ?? lastLimits.max(by: { $0.percent < $1.percent })

        if let d = driver {
            driverUsed = d.percent
            driverResets = d.resetsAt
            if !hasData || resetCycle { cycleStart = Date() }
            hasData = true
            lastSignature = ""                    // force an immediate redraw
            renderNow()
        } else {
            hasData = false
            setTitle(text: " Claude —", color: .secondaryLabelColor)
        }
    }

    // MARK: - Click routing

    /// Clicking the sprite pets Claude; clicking anywhere else opens the menu.
    @objc func buttonClicked(_ sender: NSStatusBarButton) {
        let inSprite = NSApp.currentEvent.map { ev -> Bool in
            let p = sender.convert(ev.locationInWindow, from: nil)
            return p.x <= spriteHitMaxX
        } ?? false

        // Petting needs a face to react with; while dozing or error, just menu.
        if inSprite && hasData && !sleeping {
            pet()
        } else if let menu = currentMenu {
            statusItem.menu = menu          // attach, pop up, then detach so the
            sender.performClick(nil)        // next plain click reaches us again
            statusItem.menu = nil
        }
    }

    /// Show the happy face + an affection line for PETTING_HOLD seconds.
    func pet() {
        let remaining = max(0, min(100, 100 - (driverUsed ?? 0)))
        var pool = pettingLines(mood: mood(remaining: remaining))
        if pool.count > 1 { pool.removeAll { $0 == lastPettingLine } }
        let line = pool.randomElement() ?? lastPettingLine
        lastPettingLine = line
        pettingLine = line
        pettingUntil = Date().addingTimeInterval(PETTING_HOLD)
        lastSignature = ""      // force an immediate redraw
        renderNow()
    }

    /// Menu action: switch which limit the widget tracks; remember the choice.
    @objc func selectLimit(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        selectedKind = kind
        UserDefaults.standard.set(kind, forKey: "selectedKind")
        updateDriver(resetCycle: true)
        rebuildMenu()                             // rebuild to move the checkmark
    }

    /// Rebuild `currentMenu` from the latest result. Anything that changes what
    /// the menu shows — a new limit selection, an available update, the
    /// launch-at-login state — funnels through here so all three menu shapes
    /// (usage / dozing / error) stay in sync.
    func rebuildMenu() {
        if last.rateLimited {
            currentMenu = errorMenu("요청이 많아 잠시 쉬는 중이에요.\n곧 자동으로 다시 시도합니다.",
                                    showCompactToggle: true)
        } else if let err = last.error {
            currentMenu = errorMenu(err)
        } else {
            currentMenu = usageMenu(last)
        }
    }

    /// Items shared by every menu shape: update status, launch-at-login, quit.
    func appendCommonItems(to menu: NSMenu) {
        menu.addItem(.separator())

        if isUpdating {
            let item = NSMenuItem(title: "업데이트 설치 중…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if let up = availableUpdate {
            let item = NSMenuItem(title: "🎁 새 버전 \(up.version) 설치",
                                  action: #selector(installUpdateNow), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "업데이트 확인 (v\(APP_VERSION))",
                                  action: #selector(checkForUpdateNow), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let login = NSMenuItem(title: "로그인 시 자동 시작",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    func usageMenu(_ result: UsageResult) -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "추적할 한도 (✓ 선택됨)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Order: session, weekly_all, then scoped
        let order = ["session", "weekly_all", "weekly_scoped"]
        let sorted = result.limits.sorted {
            (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9)
        }

        for l in sorted {
            let remaining = Double(100 - l.percent) / 100.0
            let bar = batteryBar(remaining: remaining)

            // Clickable row: selects this limit as the tracked one.
            let title = NSMenuItem(title: "\(label(for: l))   \(l.percent)% 사용",
                                   action: #selector(selectLimit(_:)), keyEquivalent: "")
            title.target = self
            title.representedObject = l.kind
            title.state = (l.kind == selectedKind) ? .on : .off   // checkmark
            menu.addItem(title)

            // Bar + reset (informational)
            let barItem = NSMenuItem(title: "", action: #selector(selectLimit(_:)), keyEquivalent: "")
            barItem.target = self
            barItem.representedObject = l.kind
            let s = NSMutableAttributedString(string: "     \(bar)   리셋 \(resetIn(l.resetsAt))")
            s.addAttribute(.font,
                           value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                           range: NSRange(location: 0, length: s.length))
            let barLen = bar.count + 5
            s.addAttribute(.foregroundColor, value: color(remaining: remaining),
                           range: NSRange(location: 0, length: min(barLen, s.length)))
            barItem.attributedTitle = s
            menu.addItem(barItem)

            menu.addItem(.separator())
        }

        let compactItem = NSMenuItem(title: "간결 모드 (메뉴바 폭 줄이기)",
                                     action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.target = self
        compactItem.state = compact ? .on : .off
        menu.addItem(compactItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "지금 새로고침", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        appendCommonItems(to: menu)
        return menu
    }

    /// Menu action: toggle compact mode (hides Lv, shrinks the dialogue font)
    /// so the widget fits menu bars with limited space; choice persists.
    @objc func toggleCompact() {
        compact.toggle()
        UserDefaults.standard.set(compact, forKey: "compact")
        lastSignature = ""
        renderNow()
        rebuildMenu()                       // rebuild to move the checkmark
    }

    func errorMenu(_ msg: String, showCompactToggle: Bool = false) -> NSMenu {
        let menu = NSMenu()

        if msg == NO_TOKEN_ERROR {
            // Not really an error from the user's side — they just haven't logged
            // in yet. Say what to do, and offer the how.
            let item = NSMenuItem(title: "Claude Code에 로그인이 필요합니다", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let how = NSMenuItem(title: "로그인하는 방법 보기…",
                                 action: #selector(showLoginHelp), keyEquivalent: "")
            how.target = self
            menu.addItem(how)
        } else {
            let item = NSMenuItem(title: "오류: \(msg)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let hint = NSMenuItem(title: "Claude Code에 로그인돼 있는지 확인하세요", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        if showCompactToggle {
            let compactItem = NSMenuItem(title: "간결 모드 (메뉴바 폭 줄이기)",
                                         action: #selector(toggleCompact), keyEquivalent: "")
            compactItem.target = self
            compactItem.state = compact ? .on : .off
            menu.addItem(compactItem)
            menu.addItem(.separator())
        }
        let refreshItem = NSMenuItem(title: "다시 시도", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        appendCommonItems(to: menu)
        return menu
    }

    @objc func refreshNow() { isMocking ? applyMock() : refresh() }

    /// Render the app icon from the same pixel grid the widget uses, so the icon
    /// can never drift from the sprite. make-icon.sh turns this into a .icns.
    func writeIconPNG(to path: String) {
        let side: CGFloat = 1024
        let grid = spriteGrids[.happy]![0]     // the smiling face reads best small
        let cols = CGFloat(grid[0].count), rows = CGFloat(grid.count)

        // Fit the sprite into ~66% of the canvas, keeping pixels square, then
        // center it. macOS icons want visible breathing room at the edges.
        let cell = (side * 0.66 / max(cols, rows)).rounded(.down)
        let w = cols * cell, h = rows * cell

        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Rounded-square backdrop in Claude's cream, matching the widget pill.
            let inset = rect.insetBy(dx: side * 0.06, dy: side * 0.06)
            NSColor(srgbRed: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()
            NSBezierPath(roundedRect: inset, xRadius: side * 0.18, yRadius: side * 0.18).fill()

            drawSprite(grid,
                       origin: NSPoint(x: (side - w) / 2, y: (side - h) / 2),
                       cell: cell)
            return true
        }
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// Debug helper: stack sample widgets (varied HP + a mid-crossfade frame) into one PNG.
    func dumpSamples(to path: String) {
        driverResets = Date().addingTimeInterval(3600 + 47 * 60)
        let samples: [(Int, String, String?, CGFloat)] = [
            (5,  "포켓몬센터까지 1시간 47분", nil, 1),       // healthy
            (55, "포켓몬센터까지 32분", nil, 1),            // tired
            (78, "클로드가 울상을 짓고 있다.", nil, 1),   // hurt, flavor showing
            (78, "클로드가 울상을 짓고 있다.", "포켓몬센터까지 12분", 0.5), // mid-crossfade
            (100, "클로드가 쓰러졌다!", nil, 1), // fainted
        ]
        var imgs = samples.map { buildImage(used: $0.0, remaining: 100 - $0.0, bob: 0,
                                            blink: false, primary: $0.1, secondary: $0.2, alpha: $0.3) }
        // dozing WITH prior data (gray bar at last HP)
        imgs.append(buildImage(used: 41, remaining: 59, bob: 0, blink: true,
                               primary: SLEEP_MESSAGE, secondary: nil, alpha: 1, sleeping: true))
        // dozing WITHOUT data (placeholder --/100)
        imgs.append(buildImage(used: 0, remaining: 0, bob: 0, blink: true,
                               primary: SLEEP_MESSAGE, secondary: nil, alpha: 1, sleeping: true, hpUnknown: true))
        // petting: healthy Claude smiles
        imgs.append(buildImage(used: 5, remaining: 95, bob: 0, blink: false,
                               primary: "클로드가 기뻐서 빙글빙글 돈다!", secondary: nil, alpha: 1,
                               petting: true))
        // petting: fainted Claude stays fainted (no smile)
        imgs.append(buildImage(used: 100, remaining: 0, bob: 0, blink: false,
                               primary: "클로드는 쓰러져서 반응이 없다..", secondary: nil, alpha: 1,
                               petting: true))
        let maxW = imgs.map { $0.size.width }.max() ?? 200
        let rowH = NSStatusBar.system.thickness + 4
        let total = NSImage(size: NSSize(width: maxW, height: rowH * CGFloat(imgs.count)), flipped: false) { rect in
            NSColor.darkGray.setFill(); rect.fill()
            var y = rect.height - rowH
            for im in imgs { im.draw(at: NSPoint(x: 2, y: y + 2), from: .zero, operation: .sourceOver, fraction: 1); y -= rowH }
            return true
        }
        let rep = NSBitmapImageRep(data: total.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
