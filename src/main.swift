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

/// Sentinel error meaning the token exists but the server rejected it (HTTP 401)
/// — the OAuth access token has expired. Claude Code refreshes it whenever it
/// runs, so overnight (CLI unused) the token lapses and this widget sees a 401.
/// Answered with re-auth guidance, same as NO_TOKEN_ERROR.
let EXPIRED_TOKEN_ERROR = "로그인 만료"

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

/// Petting reactions shown only while wearing a rare skin — the shiny reacts as
/// itself, not as a recolored Claude. Kept separate from pettingLines(mood:) so
/// they read as belonging to the skin rather than to the HP state.
///
/// Anything added here MUST also reach allSlotStrings(), or the first time one of
/// these appears the widget's slot resizes and the whole thing lurches.
func shinyPettingLines() -> [String] {
    [
        "이로치 클로드가 반짝반짝 빛난다!",
        "이로치 클로드가 자랑스럽게 뽐낸다!",
        "이로치 클로드가 눈부시게 웃는다!",
        "반짝이는 비늘이 손끝을 스친다!",
    ]
}

/// How long a petting reaction stays on screen before the normal slot cycle resumes.
let PETTING_HOLD: TimeInterval = 3.0

/// Shown instead of a countdown when the limit has no `resets_at`. The API omits
/// it for a limit whose window hasn't opened yet (nothing used ⇒ nothing to
/// reset), e.g. weekly_scoped before its first request. There is no arrival to
/// wait for, so say we're already there.
let ARRIVED_MESSAGE = "포켓몬센터 도착!"

/// The dialogue slot's countdown line: "time until the Pokémon Center" (i.e.
/// until the tracked limit resets). Returns the whole line, not just the
/// duration, because the no-countdown case drops the prefix entirely.
func resetKorean(_ date: Date?) -> String {
    guard let date = date else { return ARRIVED_MESSAGE }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return ARRIVED_MESSAGE }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    let left: String
    if d > 0      { left = "\(d)일 \(h)시간" }
    else if h > 0 { left = "\(h)시간 \(m)분" }
    else          { left = "\(m)분" }
    return "포켓몬센터까지 \(left)"
}

/// Every string the dialogue slot might ever display — used to reserve a fixed
/// slot width so the widget never reflows when the text swaps or the clock ticks.
func allSlotStrings() -> [String] {
    var s = [90, 70, 45, 25, 10, 5, 0].map { flavorLine(remaining: $0) }
    // Sprite-click reactions share the same slot, so reserve room for them too.
    s += [Mood.healthy, .tired, .hurt, .fainted].flatMap { pettingLines(mood: $0) }
    s += shinyPettingLines()   // shown only on the shiny, but the slot must fit them
    s.append(SLEEP_MESSAGE)
    s.append(ARRIVED_MESSAGE)
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

// MARK: - Claude skins (color customization)

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

/// A recolor of Claude. The sprite grids never change — only these three body
/// tones do — so one skin applies identically to the menu-bar widget and the
/// battle screen. `unlockPets > 0` gates a skin behind a petting count (the
/// shiny), keeping it hidden until Claude has been petted that many times.
struct ClawdSkin {
    let id: String
    let name: String
    let highlight: NSColor   // battle shading 'L'
    let base: NSColor        // body 'B'
    let shadow: NSColor      // outline/shadow 'D'
    var unlockPets: Int = 0
    /// Overrides the derived outline. Only the shiny sets this — a gold keyline is
    /// how it stays distinguishable when nothing is moving, since the sparkle
    /// (below) is transient and the ★ is easy to overlook.
    var outlineOverride: NSColor? = nil

    /// The shiny is the only skin with an unlock gate, and everything that marks
    /// it as rare keys off this rather than off a literal "shiny" id, so a second
    /// gated skin would inherit the whole treatment for free.
    var isRare: Bool { unlockPets > 0 }

    /// Widget sprite is 2-tone (B/D) over fixed face details (K/W/T/M).
    var widgetColors: [Character: NSColor] {
        var c = spriteColors
        c["B"] = base
        c["D"] = shadow
        return c
    }
    /// The outline, as a deepened version of the skin's own shadow rather than
    /// black: a hard black keyline reads as a sticker pasted onto the scene, and
    /// the widget already outlines Claude in dark orange ('D' in spriteColors).
    /// Derived, not hand-picked, so every skin — and any skin added later — gets
    /// an outline that matches its body instead of one more color to keep in sync.
    var outline: NSColor {
        if let o = outlineOverride { return o }
        let c = shadow.usingColorSpace(.sRGB) ?? shadow
        return NSColor(srgbRed: c.redComponent * 0.55,
                       green: c.greenComponent * 0.55,
                       blue: c.blueComponent * 0.55, alpha: 1)
    }
    /// Battle sprite is shaded into three tones (L/B/D) over that tinted outline.
    var battleColors: [Character: NSColor] {
        ["K": outline, "L": highlight, "B": base, "D": shadow]
    }
}

/// How many pets unlock the shiny.
let PETS_TO_SHINY = 50

/// Six variants, to fill a Pokémon-style party screen: the default and the four
/// model themes, then the shiny last — it is the rare one, so it sits at the end
/// of the party (bottom-right of the 2x3 picker) rather than beside the default.
/// Colors are original recolors of our own sprite, not from any existing game.
let ALL_SKINS: [ClawdSkin] = [
    ClawdSkin(id: "default", name: "클로드",
              highlight: rgb(0xF5,0xB8,0x95), base: rgb(0xD9,0x77,0x57), shadow: rgb(0xA6,0x47,0x2E)),
    ClawdSkin(id: "opus", name: "오퍼스",
              highlight: rgb(0xCF,0xAC,0xF0), base: rgb(0x88,0x58,0xB0), shadow: rgb(0x57,0x30,0x80)),
    ClawdSkin(id: "sonnet", name: "소네트",
              highlight: rgb(0x9E,0xD0,0xF8), base: rgb(0x4A,0x82,0xC8), shadow: rgb(0x2C,0x54,0x90)),
    ClawdSkin(id: "haiku", name: "하이쿠",
              highlight: rgb(0xB4,0xEE,0xB0), base: rgb(0x58,0xB0,0x5A), shadow: rgb(0x30,0x80,0x36)),
    ClawdSkin(id: "fable", name: "페이블",
              highlight: rgb(0xFA,0xC2,0xE0), base: rgb(0xD8,0x60,0xA0), shadow: rgb(0xA0,0x38,0x70)),
    ClawdSkin(id: "shiny", name: "이로치",
              highlight: rgb(0xFC,0xF0,0xC0), base: rgb(0xF0,0xC2,0x52), shadow: rgb(0xBE,0x86,0x2E),
              unlockPets: PETS_TO_SHINY,
              outlineOverride: rgb(0x6B,0x45,0x0E)),   // warm gold-brown, not the derived near-black
]

func skin(id: String) -> ClawdSkin { ALL_SKINS.first { $0.id == id } ?? ALL_SKINS[0] }

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

// MARK: - Shiny sparkle

/// The four-pointed star of the Pokémon shiny effect, as a pixel grid so it sits
/// on the same grid as the sprites instead of looking like a vector overlay.
/// 'E' is a darker gold rim: on the panel's light gray a pure-gold star washes
/// out, so the points are edged to hold their shape.
let SPARKLE_GRID: [String] = [
    "...E...",
    "...S...",
    "..ESE..",
    ".ESWSE.",
    "ESSWSSE",
    ".ESWSE.",
    "..ESE..",
    "...S...",
    "...E...",
]

/// The menu-bar star. A 22px bar leaves the sprite ~18pt tall, and scaling the
/// 9-row grid into that gives sub-point cells — which vanish outright, since
/// drawSprite() fills with antialiasing off. So small frames get their own
/// coarse grid instead of a shrunken fine one.
let SPARKLE_GRID_SMALL: [String] = [
    ".S.",
    "SWS",
    ".S.",
]

/// Below this frame height the fine grid can't hold a whole point per cell.
let SPARKLE_SMALL_BELOW: CGFloat = 40

/// Where the stars pop, as offsets from the sprite's center in *sprite cells*, so
/// one layout works at any cell size. Each carries its own scale and the fraction
/// of the burst it appears at, so they fire in sequence rather than all at once —
/// a simultaneous pop reads as a flash, a staggered one reads as a sparkle.
let SPARKLE_BURST: [(dx: CGFloat, dy: CGFloat, scale: CGFloat, at: Double)] = [
    (-0.42,  0.34, 1.00, 0.00),
    ( 0.40,  0.18, 0.75, 0.14),
    (-0.22, -0.30, 0.70, 0.30),
    ( 0.30, -0.36, 0.55, 0.46),
]

/// How long the entrance burst lasts.
let SPARKLE_DURATION: TimeInterval = 1.1

/// Draw the burst over `frame` at `t` in 0...1. Each star fades in fast and out
/// slow within its own window, so the group twinkles instead of blinking as one.
///
/// Star size is a fraction of `frame`, never an absolute: the same call has to
/// work over a 122pt battle sprite and an 18pt one in a 22px menu bar, and a
/// fixed cell size that suits either one is grotesque in the other.
func drawSparkles(in frame: NSRect, t: Double, gold: NSColor) {
    guard t >= 0, t <= 1 else { return }
    let colors: [Character: NSColor] = ["S": gold, "W": .white, "E": SHINY_GOLD_EDGE]
    let small = frame.height < SPARKLE_SMALL_BELOW
    let grid = small ? SPARKLE_GRID_SMALL : SPARKLE_GRID
    let rows = CGFloat(grid.count)
    // The biggest star spans ~40% of the sprite's height.
    let unit = frame.height * 0.40 / rows
    for s in SPARKLE_BURST {
        let local = (t - s.at) / 0.5          // each star owns half the burst
        guard local >= 0, local <= 1 else { continue }
        // Fade: quick rise, slow fall. sin gives that shape over 0...1 for free.
        let alpha = sin(local * .pi)
        guard alpha > 0.02 else { continue }

        // Never let a cell fall below a point: drawSprite() fills with antialiasing
        // off, so a sub-point rect rounds away to nothing and the star disappears.
        let cell = max(unit * s.scale, 1)
        let w = CGFloat(grid[0].count) * cell
        let h = CGFloat(grid.count) * cell
        let origin = NSPoint(x: frame.midX + s.dx * frame.width - w / 2,
                             y: frame.midY + s.dy * frame.height - h / 2)

        NSGraphicsContext.current?.saveGraphicsState()
        // The whole star fades as one; per-cell alpha would dither at these sizes.
        let faded = colors.mapValues { $0.withAlphaComponent(CGFloat(alpha)) }
        drawSprite(grid, origin: origin, cell: cell, colors: faded)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// The shiny's star color, and the ★ used to mark it in menus.
let SHINY_GOLD = NSColor(srgbRed: 0xFF/255, green: 0xDE/255, blue: 0x6A/255, alpha: 1)
let SHINY_GOLD_EDGE = NSColor(srgbRed: 0xC8/255, green: 0x8A/255, blue: 0x18/255, alpha: 1)
let SHINY_MARK = "★"

/// The menu-bar twinkle, in animation ticks (the widget timer runs at 12fps).
/// The widget redraws only when its signature changes, so the sparkle is stepped
/// as an integer frame index: it burns ~24 frames every 30s and is idle between.
let WIDGET_SPARKLE_PERIOD = 360      // 30s at 12fps
let WIDGET_SPARKLE_FRAMES = 24       // 2s of twinkle

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
        // 401/403: the token is present but rejected — expired access token.
        if http.statusCode == 401 || http.statusCode == 403 {
            completion(UsageResult(error: EXPIRED_TOKEN_ERROR)); return
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
    if frac >= 0.5 { return GB_GREEN }   // match the battle gauge's green
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
    // Chosen Claude skin (color). Applies to both the widget and the battle
    // screen; persists across restarts. The shiny is gated behind petCount.
    var selectedSkinID: String = UserDefaults.standard.string(forKey: "clawdSkin") ?? "default"
    var petCount: Int = UserDefaults.standard.integer(forKey: "petCount")
    var currentSkin: ClawdSkin { skin(id: selectedSkinID) }
    /// A skin is pickable if it has no unlock gate or the gate is met.
    func isUnlocked(_ s: ClawdSkin) -> Bool { petCount >= s.unlockPets }
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

    // Battle screen: the drop-down panel a left-click opens.
    var battlePanel: BattlePanel?
    var battleMonitor: Any?          // dismisses the panel on a click elsewhere
    var battleClosedAt: Date?        // when the panel last closed, so a status-item
                                     // click that both dismissed AND re-triggered
                                     // buttonClicked doesn't immediately reopen it

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
        // Debug: CLAUDEMONSTER_BATTLE=<path> renders the battle panel and exits.
        // Lets the drop-down's design be checked without a window or a network call.
        if let path = ProcessInfo.processInfo.environment["CLAUDEMONSTER_BATTLE"] {
            let pct = Int(ProcessInfo.processInfo.environment["CLAUDEMONSTER_MOCK_PERCENT"] ?? "") ?? 16
            dumpBattle(to: path, usedPercent: pct); exit(0)
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
                } else {
                    // A hand-triggered check needs an answer on the spot. Rebuilding
                    // the menu adds the 🎁 item, but the menu the user just clicked
                    // is already drawn, so silently doing nothing reads as a no-op.
                    self.installUpdateNow()
                }
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

    /// Menu action: shown on a 401 — the token expired and needs refreshing.
    @objc func showReauthHelp() {
        let a = NSAlert()
        a.messageText = "로그인이 만료됐어요"
        a.informativeText = """
            Claude Code 로그인 토큰은 약 8시간마다 만료되고, Claude Code를 \
            실행하면 자동으로 갱신됩니다. 밤새 Claude Code를 쓰지 않으면 토큰이 \
            만료돼 이 위젯에 401 오류가 뜰 수 있어요.

            갱신하려면:
            1. 터미널에서 claude 를 한 번 실행합니다 (로그인돼 있으면 자동 갱신됨)
            2. 이 메뉴에서 "다시 시도"를 누릅니다
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
            // Mirrors what the API actually returns for an untouched scoped limit:
            // nothing used, so its weekly window never opened and resets_at is null.
            // That's the case the "포켓몬센터 도착!" line exists for — keep it here
            // so mock mode can still reach it.
            Limit(kind: "weekly_scoped", percent: 0,
                  resetsAt: nil, scopeName: "Fable", isActive: false),
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
        let timeText = resetKorean(driverResets)
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

        // The shiny twinkles in the menu bar every WIDGET_SPARKLE_PERIOD ticks, so
        // its rarity shows even when no panel is open. A fainted Claude does not
        // sparkle — the joke lands badly at 0 HP.
        // Quantized to a frame index (not a continuous alpha) because it has to go
        // into lastSignature, and a float there would defeat the cheap-skip.
        var sparkleFrame = -1
        if currentSkin.isRare && !isFainted && !sleeping {
            let p = animTick % WIDGET_SPARKLE_PERIOD
            if p < WIDGET_SPARKLE_FRAMES { sparkleFrame = p }
        }

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

        // skin and sparkleFrame are part of what's on screen, so they belong in the
        // signature — leave either out and the widget keeps the stale image.
        let sig = "\(used)|\(hpUnknown)|\(bob)|\(blink)|sleep=\(sleeping)|pet=\(petting)|\(compact)|\(primary)|\(secondary ?? "")|\(Int(alpha * 12))|\(selectedSkinID)|spk=\(sparkleFrame)"
        if sig == lastSignature { return }
        lastSignature = sig

        let img = buildImage(used: used, remaining: remaining, bob: CGFloat(bob),
                             blink: blink, primary: primary, secondary: secondary, alpha: alpha,
                             sleeping: sleeping, hpUnknown: hpUnknown, compact: compact,
                             petting: petting, sparkleFrame: sparkleFrame)
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.image = img
        statusItem.button?.imagePosition = .imageOnly
    }

    func buildImage(used: Int, remaining: Int, bob: CGFloat, blink: Bool,
                    primary: String, secondary: String?, alpha: CGFloat,
                    sleeping: Bool = false, hpUnknown: Bool = false, compact: Bool = false,
                    petting: Bool = false, sparkleFrame: Int = -1) -> NSImage {
        // When HP is unknown (dozing before any data), the gauge is empty gray.
        let frac: CGFloat = hpUnknown ? 1 : CGFloat(remaining) / 100.0
        // Gauge turns gray while dozing.
        let hpColor = sleeping ? NSColor.systemGray : color(remaining: Double(frac))
        let black = NSColor.black

        let name = "클로드"
        let lv = hpUnknown ? ":Lv--" : ":Lv\(used)"
        let hpLabel = "HP:"
        let hpText = hpUnknown ? "--/100" : "\(remaining)/100"

        // Compact mode shrinks the name too — on a 14" menu bar every point counts.
        let nameAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(compact ? 12 : 15), .foregroundColor: black]
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
        // Compact mode tightens the spacing to match its smaller text — at 9pt the
        // roomier gaps read as gaps, not breathing room.
        let padX: CGFloat = compact ? 5 : 7
        let gap: CGFloat = compact ? 4 : 5
        let spriteNameGap: CGFloat = compact ? 5 : 7   // 스프라이트 ↔ 이름 간격 (이 숫자를 키우면 더 벌어짐)
        let flavorGap: CGFloat = compact ? 7 : 10
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
            // Fainted stays grayscale regardless of skin; otherwise use the skin.
            let colors: [Character: NSColor] = remaining == 0 ? spriteColorsFainted : self.currentSkin.widgetColors
            drawSprite(grid, origin: spriteOrigin, cell: cell, colors: colors)

            // The shiny's periodic twinkle. Drawn inside the sprite's own box so it
            // cannot widen the widget — the menu bar gives us 22px and no more.
            if sparkleFrame >= 0 {
                let t = Double(sparkleFrame) / Double(WIDGET_SPARKLE_FRAMES)
                drawSparkles(in: NSRect(x: spriteOrigin.x, y: spriteOrigin.y,
                                        width: spriteW, height: spriteH),
                             t: t, gold: SHINY_GOLD)
            }
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

    /// Clicking the sprite pets Claude. A left-click elsewhere drops down the
    /// battle screen; a right-click still opens the plain menu — that menu is
    /// the only way to quit, so it must stay reachable even if the panel breaks.
    @objc func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // sendAction(on:) synthesizes the event, so locationInWindow is the
        // button's center, not the mouse. Ask the system where the cursor is.
        let inSprite: Bool = {
            guard let win = sender.window else { return false }
            let screenP = NSEvent.mouseLocation
            let winP = win.convertPoint(fromScreen: screenP)
            let p = sender.convert(winP, from: nil)
            // spriteHitMaxX is in image coordinates; .imageOnly centers the
            // image in the button, so shift by the leftover margin.
            let originX = (sender.bounds.width - (sender.image?.size.width ?? sender.bounds.width)) / 2
            return p.x >= originX && p.x - originX <= spriteHitMaxX
        }()
        let isRightClick = event.map {
            $0.type == .rightMouseUp || $0.modifierFlags.contains(.control)
        } ?? false

        // Petting needs a face to react with; while dozing or error, just menu.
        if inSprite && hasData && !sleeping {
            pet()
        } else if isRightClick || !hasData || sleeping {
            // No data means no HP to draw, so fall back to the menu, which also
            // explains *why* (login needed / rate-limited).
            popUpMenu(sender)
        } else {
            toggleBattlePanel(sender)
        }
    }

    private func popUpMenu(_ sender: NSStatusBarButton) {
        guard let menu = currentMenu else { return }
        statusItem.menu = menu          // attach, pop up, then detach so the
        sender.performClick(nil)        // next plain click reaches us again
        statusItem.menu = nil
    }

    // MARK: - Battle panel

    func toggleBattlePanel(_ sender: NSStatusBarButton) {
        if battlePanel != nil { closeBattlePanel(); return }
        // If the global monitor just closed the panel from this very click, don't
        // reopen — clicking the status item while open should close, not re-toggle.
        if let t = battleClosedAt, Date().timeIntervalSince(t) < 0.3 { return }
        openBattlePanel(sender)
    }

    func openBattlePanel(_ button: NSStatusBarButton) {
        let view = BattleView(frame: NSRect(x: 0, y: 0, width: BATTLE_W, height: BATTLE_H),
                              usedPercent: driverUsed ?? 0, limits: lastLimits,
                              selectedKind: selectedKind, compactOn: compact,
                              skinID: selectedSkinID, petCount: petCount)
        view.perform = { [weak self, weak view] action in
            self?.runBattleAction(action, from: view)
        }
        view.onDismiss = { [weak self] in self?.closeBattlePanel() }

        let panel = BattlePanel(contentRect: view.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = view

        // Sit under the status item, clamped into the screen on both axes — a
        // short screen would otherwise cut the panel's bottom off.
        var origin = NSPoint.zero
        if let win = button.window {
            let f = win.frame
            var x = f.midX - BATTLE_W / 2
            var y = f.minY - BATTLE_H - 4
            if let vis = (win.screen ?? NSScreen.main)?.visibleFrame {
                x = min(max(x, vis.minX + 8), vis.maxX - BATTLE_W - 8)
                y = max(y, vis.minY + 8)
                y = min(y, vis.maxY - BATTLE_H - 4)
            }
            origin = NSPoint(x: x, y: y)
        }

        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 8))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(view)      // or arrow keys / Enter never reach it
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
            panel.animator().alphaValue = 1
        }
        battlePanel = panel

        // NSPopover's .transient, by hand. Esc is handled inside the view, which
        // steps back a page before dismissing (via onDismiss at the root).
        battleMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeBattlePanel()
        }
    }

    /// Run a battle-menu action. Anything that changes tracked state goes through
    /// the same methods the right-click menu uses, so the widget and the panel
    /// can never disagree; afterwards the panel is refreshed from the new state.
    func runBattleAction(_ action: BattleAction, from view: BattleView?) {
        switch action {
        case .pickLimit(let kind):
            selectLimit(kind: kind)          // redraws the widget (Lv + HP)
            refreshBattleView(view)
        case .pickSkin(let id):
            selectSkin(id: id)               // recolors the widget
            refreshBattleView(view)
            view?.go(to: .root)              // back out of the picker after choosing
        case .toggleCompact:
            toggleCompact()                  // redraws the widget
            refreshBattleView(view)
        case .checkUpdate:
            // The alert is modal; the panel would hang behind it, so dismiss first.
            closeBattlePanel()
            checkForUpdate(userInitiated: true)
        case .refresh:
            // Fetching is async, so the panel can only be refreshed once apply()
            // has landed the new numbers — hence the delay rather than an
            // immediate refreshBattleView(), which would redraw the old data.
            refreshNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak view] in
                self?.refreshBattleView(view)
            }
        case .quit:
            closeBattlePanel()
            NSApp.terminate(nil)
        case .openUsage, .openMore, .openSkins, .openBattle, .tackle, .back, .none:
            break                            // handled inside the view
        }
    }

    /// Switch the Claude skin; remember it. Redraws the widget immediately.
    func selectSkin(id: String) {
        selectedSkinID = id
        UserDefaults.standard.set(id, forKey: "clawdSkin")
        lastSignature = ""       // force the widget to repaint in the new color
        renderNow()
    }

    /// Push the delegate's current state back into the open panel.
    private func refreshBattleView(_ view: BattleView?) {
        guard let view = view else { return }
        let wasShiny = view.isShiny
        view.usedPercent = driverUsed ?? 0
        view.limits = lastLimits
        view.selectedKind = selectedKind
        view.compactOn = compact
        view.skinID = selectedSkinID
        view.petCount = petCount
        // Switching *into* the shiny replays the burst — that pick is the payoff
        // for 50 pets. Only on the transition, or every refresh would re-fire it.
        if !wasShiny && view.isShiny { view.startSparkle() }
        view.needsDisplay = true
    }

    func closeBattlePanel() {
        if let m = battleMonitor { NSEvent.removeMonitor(m); battleMonitor = nil }
        guard let panel = battlePanel else { return }
        // Clear the reference first: the animation outlives this call, and a
        // click landing mid-fade would otherwise toggle against a dying panel.
        battlePanel = nil
        battleClosedAt = Date()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// Show the happy face + an affection line for PETTING_HOLD seconds. Each pet
    /// counts toward unlocking the shiny skin; the count persists.
    func pet() {
        let remaining = max(0, min(100, 100 - (driverUsed ?? 0)))
        let m = mood(remaining: remaining)
        // The shiny gets its own reactions — but a fainted Claude stays fainted,
        // so the somber lines still win. Rarity does not outrank 0 HP.
        var pool = (currentSkin.isRare && m != .fainted)
            ? shinyPettingLines()
            : pettingLines(mood: m)
        if pool.count > 1 { pool.removeAll { $0 == lastPettingLine } }
        let line = pool.randomElement() ?? lastPettingLine
        lastPettingLine = line
        pettingLine = line
        pettingUntil = Date().addingTimeInterval(PETTING_HOLD)
        lastSignature = ""      // force an immediate redraw
        renderNow()

        let wasLocked = petCount < PETS_TO_SHINY
        petCount += 1
        UserDefaults.standard.set(petCount, forKey: "petCount")
        if wasLocked && petCount >= PETS_TO_SHINY {
            // Cross the threshold exactly once — tell the user the shiny appeared.
            DispatchQueue.main.asyncAfter(deadline: .now() + PETTING_HOLD) { [weak self] in
                self?.alert("이로치 클로드 해금!",
                            "정성껏 쓰다듬어 줬네요. '색상 커스텀'에서 이로치 클로드를 고를 수 있어요.")
            }
        }
    }

    /// Switch which limit the widget tracks; remember the choice. Shared by the
    /// right-click menu and the battle screen, so both stay in step — the widget
    /// redraws either way.
    func selectLimit(kind: String) {
        selectedKind = kind
        UserDefaults.standard.set(kind, forKey: "selectedKind")
        updateDriver(resetCycle: true)
        rebuildMenu()                             // rebuild to move the checkmark
    }

    /// Menu action: switch which limit the widget tracks.
    @objc func selectLimitFromMenu(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        selectLimit(kind: kind)
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
                                   action: #selector(selectLimitFromMenu(_:)), keyEquivalent: "")
            title.target = self
            title.representedObject = l.kind
            title.state = (l.kind == selectedKind) ? .on : .off   // checkmark
            menu.addItem(title)

            // Bar + reset (informational)
            let barItem = NSMenuItem(title: "", action: #selector(selectLimitFromMenu(_:)), keyEquivalent: "")
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

        let compactItem = NSMenuItem(title: "좁게 보기 (메뉴바 폭 줄이기)",
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
        } else if msg == EXPIRED_TOKEN_ERROR {
            // Token lapsed. Running Claude Code once refreshes it; say so.
            let item = NSMenuItem(title: "로그인이 만료됐습니다", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            let how = NSMenuItem(title: "갱신하는 방법 보기…",
                                 action: #selector(showReauthHelp), keyEquivalent: "")
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
            let compactItem = NSMenuItem(title: "좁게 보기 (메뉴바 폭 줄이기)",
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

    /// Debug helper: render the battle panel offscreen so its design can be
    /// inspected without opening a window or touching the network.
    func dumpBattle(to path: String, usedPercent: Int) {
        let now = Date()
        let fixture = [
            Limit(kind: "session", percent: usedPercent,
                  resetsAt: now.addingTimeInterval(3600 * 2), scopeName: nil, isActive: true),
            Limit(kind: "weekly_all", percent: 55,
                  resetsAt: now.addingTimeInterval(86400 * 3), scopeName: nil, isActive: false),
            Limit(kind: "weekly_scoped", percent: 0,
                  resetsAt: nil, scopeName: "Fable", isActive: false),
        ]
        // All menu pages, stacked, so a design change can be checked at once.
        // The skin picker is shown with the shiny unlocked so its cell renders.
        // CLAUDEMONSTER_ONEPAGE=1 dumps only the root page, so indicator tweaks can
        // be zoomed without the tall five-page stack.
        let pages: [BattleScreen] = ProcessInfo.processInfo.environment["CLAUDEMONSTER_ONEPAGE"] != nil
            ? [.root]
            : [.root, .battle, .usage, .more, .skins]
        let gap: CGFloat = 10
        let size = NSSize(width: BATTLE_W, height: (BATTLE_H + gap) * CGFloat(pages.count) - gap)
        let img = NSImage(size: size, flipped: false) { rect in
            // cacheDisplay leaves everything outside the rounded panel transparent,
            // which a PNG viewer paints white — that reads as a rendering bug when
            // the live panel is simply see-through. Lay down a backdrop first.
            NSColor(white: 0.25, alpha: 1).setFill(); rect.fill()
            var y = size.height - BATTLE_H
            for page in pages {
                // CLAUDEMONSTER_SKIN=<id> dumps the panel wearing that skin, so the
                // shiny's gold outline and ★ can be checked without 50 real pets.
                let dumpSkin = ProcessInfo.processInfo.environment["CLAUDEMONSTER_SKIN"] ?? "default"
                let view = BattleView(frame: NSRect(x: 0, y: 0, width: BATTLE_W, height: BATTLE_H),
                                      usedPercent: usedPercent, limits: fixture,
                                      selectedKind: "session", compactOn: true,
                                      skinID: dumpSkin, petCount: PETS_TO_SHINY)
                view.go(to: page)
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    rep.draw(in: NSRect(x: 0, y: y, width: BATTLE_W, height: BATTLE_H))
                }
                y -= BATTLE_H + gap
            }
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

// MARK: - Battle screen (click-to-open panel)
//
// Clicking the widget drops down a Pokémon-style battle screen. It is a
// borderless NSPanel, not an NSPopover: a popover forces an arrow and the
// system's translucent material, neither of which can be removed, and both
// clash with the pixel art. The cost is that "click outside to dismiss" —
// free with popovers — has to be built by hand (see the global event monitor).
//
// Menu interaction is not wired up yet; the four items are inert. The right
// -click NSMenu remains the way to quit, so a broken panel can never strand
// the user with no way out.

/// The battle screen's palette. GBC allowed three colors plus transparency per
/// sprite; we keep that constraint (highlight / base / shadow + black outline).
let GB_BG      = NSColor(white: 0.90, alpha: 1)   // same pill gray as the widget
let GB_INK     = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
let GB_GREEN   = NSColor(srgbRed: 0x40/255, green: 0xB9/255, blue: 0x3E/255, alpha: 1)
let GB_ORANGE  = NSColor(srgbRed: 0xF8/255, green: 0xA8/255, blue: 0x28/255, alpha: 1)
let GB_RED     = NSColor(srgbRed: 0xE8/255, green: 0x30/255, blue: 0x30/255, alpha: 1)
let GB_EXP     = NSColor(srgbRed: 0x40/255, green: 0x90/255, blue: 0xE8/255, alpha: 1)
let GB_YELLOW  = NSColor(srgbRed: 0xF8/255, green: 0xD0/255, blue: 0x28/255, alpha: 1)

func gaugeColor(_ frac: CGFloat) -> NSColor {
    if frac >= 0.5 { return GB_GREEN }
    if frac >= 0.2 { return GB_ORANGE }
    return GB_RED
}

// Claude's battle colors now come from the selected skin (skin(id:).battleColors);
// the "default" skin reproduces the original orange.

/// A ghost monster's palette: a dark core wrapped in purple gas. 'B' is the gas
/// (three tones, shaded), 'C' the near-black core, 'G' its gray highlight, 'W'
/// the eyes, 'R' the red marks, 'M' the tongue.
let bugColors: [Character: NSColor] = [
    ".": .clear,

    // Outline
    "K": NSColor(srgbRed: 0x1F/255, green: 0x24/255, blue: 0x18/255, alpha: 1),

    // Body (다크 올리브)
    "D": NSColor(srgbRed: 0x4B/255, green: 0x5A/255, blue: 0x2E/255, alpha: 1),

    // Highlight (연두 광택)
    "G": NSColor(srgbRed: 0xB8/255, green: 0xD9/255, blue: 0x7A/255, alpha: 1),

    // Face
    "W": .white,

    // Orange (더듬이/집게)
    "O": NSColor(srgbRed: 0xE0/255, green: 0x8A/255, blue: 0x2E/255, alpha: 1),

    // Mouth (붉은 반점)
    "L": NSColor(srgbRed: 0xD9/255, green: 0x5A/255, blue: 0x4A/255, alpha: 1),

    // Wing Aura (이끼 그린)
    "P": NSColor(srgbRed: 0x6F/255, green: 0xA8/255, blue: 0x3E/255, alpha: 1),

    // Wing Aura (shadow)
    "S": NSColor(srgbRed: 0x4E/255, green: 0x7A/255, blue: 0x2A/255, alpha: 1),

    // Mouth (muted edge)
    "M": NSColor(srgbRed: 0xB0/255, green: 0x6E/255, blue: 0x5A/255, alpha: 1),
]

/// Easter egg: the bug repainted as a ladybug (무당벌레). Keyed identically to
/// bugColors, so it is a pure palette swap over the same bugBase grid — no cells
/// are added or moved. Retune these RGBs freely; only the keys must stay in sync
/// with bugColors, or a glyph the grid uses would render as nothing.
///
/// Unlocked by clicking the enemy's black HP plate seven times: the Korean
/// ladybug is 칠성무당벌레 — the seven-spotted one.
let LADYBUG_CLICKS = 7

/// How long the egg's barker holds the dialogue slot before the menu's own
/// message comes back.
let LADYBUG_FLASH_HOLD: TimeInterval = 2.6

let ladybugColors: [Character: NSColor] = [
    ".": .clear,

    // Outline (가장 어두운 빨강)
    "K": NSColor(srgbRed: 0x40/255, green: 0x0C/255, blue: 0x0A/255, alpha: 1),

    // Body (어두운 빨강 — Wing Shell보다 어둡게)
    "D": NSColor(srgbRed: 0x7A/255, green: 0x16/255, blue: 0x13/255, alpha: 1),

    // Highlight (광택)
    "G": NSColor(srgbRed: 0xF4/255, green: 0xA6/255, blue: 0xA0/255, alpha: 1),

    // Face
    "W": .white,

    // Antenna / Spots (검은 반점)
    "O": NSColor(srgbRed: 0x1F/255, green: 0x1F/255, blue: 0x1F/255, alpha: 1),

    // Mouth (검은 반점 포인트)
    "L": NSColor(srgbRed: 0x2A/255, green: 0x2A/255, blue: 0x2A/255, alpha: 1),

    // Wing Shell (중간 빨강)
    "P": NSColor(srgbRed: 0xB8/255, green: 0x24/255, blue: 0x1F/255, alpha: 1),

    // Wing Shell (shadow, Body보다는 밝고 Wing Shell보다는 어둡게)
    "S": NSColor(srgbRed: 0x94/255, green: 0x20/255, blue: 0x1B/255, alpha: 1),

    // Mouth (muted edge)
    "M": NSColor(srgbRed: 0xE6/255, green: 0x7A/255, blue: 0x73/255, alpha: 1),
]

let bugBase: [String] = [
    "...........SS.S.........", // 00
    "...........SS...........", // 01
    ".......SSS.....SS..SS...", // 02
    ".....SSPPPSSS.SPPS.SS...", // 03
    "....SPPPKKKKPPPPPPS.....", // 04
    "....SPKKDDDDKKPPPPS.....", // 05
    "...KSKDDDDDDDDKPPS......", // 06
    "..KWKDDDDDDDDDDKPS.SS...", // 07
    "..KWDDDDDDDDDDDKPPSPPS..", // 08
    "..KWWKDDDDDDDWDDKPPPPS..", // 09
    "SSKWPKDKDDDWWWDDKPPPS..S", // 10
    "SSKWPWDKDWWWWWKDKPPS.SS.", // 11
    "SSPKWDDDWPWWWWKDKPPS.SS.", // 12
    "..SSKDDKWPWWWKDKPPPPS...", // 13
    "....KDDDKWWWDDDKPPPPS...", // 14
    "...SPKMMMDDDMDKPPPPS....", // 15
    "...SPPKKLLM.KKPSPPS.....", // 16
    "....SPPPKKKGKPS.SS......", // 17
    ".....SPPSSPKSS..........", // 18
    "......SS..SS...SS.......", // 19
    "...............SS.......", // 20
]

/// The bug taking a hit: its left eye squeezes shut (the white sliver becomes body
/// with a dark lid line) and its mouth closes to a single dark line. Same grid size
/// and glyphs as bugBase, so it is a drop-in swap while the hit flash plays.
let bugHurtBase: [String] = [
    "...........SS.S.........", // 00
    "...........SS...........", // 01
    ".......SSS.....SS..SS...", // 02
    ".....SSPPPSSS.SPPS.SS...", // 03
    "....SPPPKKKKPPPPPPS.....", // 04
    "....SPKKDDDDKKPPPPS.....", // 05
    "...KSKDDDDDDDDKPPS......", // 06
    "..KKDDDDDDDDDDDKPS.SS...", // 07
    "..KDDDDDDDDDDDDKPPSPPS..", // 08
    "..KKDKDDDDDDDDDDKPPPPS..", // 09
    "SSKWKKDKDDDDWWDDKPPPS..S", // 10
    "SSKWPDDKDDWWWWKDKPPS.SS.", // 11
    "SSPKWKDDDPWWWWKDKPPS.SS.", // 12
    "..SSKDDKWPWWWKDKPPPPS...", // 13
    "....KDDDKWWWDDDKPPPPS...", // 14
    "...SPKKKKKKKDDKPPPPS....", // 15
    "...SPPKKDDDDKKPSPPS.....", // 16
    "....SPPPKKKKKPS.SS......", // 17
    ".....SPPSSPKSS..........", // 18
    "......SS..SS...SS.......", // 19
    "...............SS.......", // 20
]

/// Light comes from the top-left. Each body ('B') cell's tone follows a diagonal
/// gradient (horizontal position within its row + vertical position overall),
/// and only the cells where two tones meet get checkerboard-dithered.
///
/// Dithering whole columns instead produces vertical stripes that read as grime,
/// not as retro shading — the boundary is the only place it belongs.
func battleShaded(_ grid: [String], flatten: Bool = false) -> [String] {
    let rows = grid.count
    return grid.enumerated().map { (r, line) -> String in
        var chars = Array(line)
        let body = chars.indices.filter { chars[$0] == "B" }
        guard let first = body.first, let last = body.last, last > first else { return line }
        for i in body {
            let u = Double(i - first) / Double(last - first)
            let v = Double(r) / Double(max(rows - 1, 1))
            // A flat body (the bug's shell) leans on horizontal position alone.
            let t = flatten ? (0.75 * u + 0.25 * v) : (0.55 * u + 0.45 * v)
            let dither = (r + i) % 2 == 0
            switch t {
            case ..<0.26: chars[i] = "L"
            case ..<0.34: chars[i] = dither ? "L" : "B"
            case ..<0.62: chars[i] = "B"
            case ..<0.70: chars[i] = dither ? "D" : "B"
            default:      chars[i] = "D"
            }
        }
        return String(chars)
    }
}

/// Claude from behind, hand-shaded. 24x21 — the bug's density, so the two sprites
/// read as the same era instead of the widget's 20x14 grid blown up beside it.
///
/// This no longer derives from clawdBase. The widget grid is drawn for a 22px
/// menu bar and only ever loses its face here, which left the back as a flat
/// blob next to the bug. Shape (silhouette, ears, the neck crease, where the
/// limbs clear the body) is now authored here and is deliberately NOT synced to
/// the widget. Color still is: the glyphs are exactly the four ClawdSkin.battleColors
/// keys, so every skin recolors this for free.
///   K = outline · L = lit (upper-left) · B = base · D = shadow (lower-right)
/// Adding a fifth glyph would render as nothing — battleColors has no key for it.
///
/// Light comes from the upper-left, so L hugs the top-left curve of the head and
/// back, D pools along the lower-right and under the head where it overhangs the
/// body. Gen-2 backs are lit this way and carry no spine seam.
///
/// The arms are held out to the sides, as in the Clawd mascot — short, stubby,
/// and clear of the body so the silhouette reads as a pose rather than a slab.
/// They are the widest part of the sprite, so the body is narrowed to make room
/// for them inside the same 24 columns.
///
/// Rows 18-20 (the lower body) are drawn but never seen: the dialog box crops
/// them, exactly as a Gen-2 back sprite is cropped at the waist. That is intended
/// — do not raise the sprite to reveal them.
let clawdBackBase: [String] = [
    "........KKKKKKKKK.........", // 00  ear tips
    "......KKLLLLBBBDDKK.......", // 01  near ear is lit, far ear sits in shade
    ".....KKLLLBBBBBBDDDKK.....", // 02  ears meet the head
    "....KKLLLBBBBBBBBBDDDK....", // 03  back of the head: L mass upper-left,
    "....KLLLBBBBBBBBBBBDDDK...", // 04  D mass lower-right, B between them
    "....KLLBBBBBBBBBBBBBDDK...", // 05
    "....KLLBBBBBBBBBBBBBDDK...", // 06
    "....KLLBBBBBBBBBBBBBDDK...", // 07  neck crease: shadow pools under the head
    "....KLLBBBBBBBBBBBBBDDK...", // 08  shoulders
    ".KKKKLLBBBBBBBBBBBBDDKKKK.", // 09  Arms spread wide. The near arm is lit and is
    "KLLLKLLBBBBBBBBBBBBDDDDDDK", // 10  cut from the torso by a K seam; the far arm has
    "KLLBKLLBBBBBBBBBBBBDDDDDDK", // 11  no seam and is filled entirely with D.
    "KKBBKLLLBBBBBBBBBBBDDDDDDK", // 12  Light comes from the upper-left, so the far arm
    ".KKKKLLLBBBBBBBBBBBDDKKKK.", // 13  can never be brighter than the shadow it sits in.
    "....KLLLBBBBBBBBBBBBDDDK..", // 14
    "....KLLLBBBBBBBBBBBBDDDK..", // 15
    "....KLLLBBBBBBBBBBBBDDDK..", // 16
    ".....KLLBKKBBKKBBKKBDDK...", // 17  underside: three gaps cut four legs, as in
    ".....KLLBKKLBKKBDKKBDDK...", // 18  the widget grid (clawdBase rows 12-13) —
    "......KKKKKKKKKKKKKKKK....", // 19  Clawd has four, not two. Below the crop line.
]

func clawdBackGrid() -> [String] { clawdBackBase }

func spriteSize(_ grid: [String], cell: CGFloat) -> NSSize {
    NSSize(width: CGFloat(grid[0].count) * cell, height: CGFloat(grid.count) * cell)
}

let BATTLE_W: CGFloat = 480
let BATTLE_H: CGFloat = 300

let BATTLE_ENEMY_NAME  = "버그"

/// Which page of the 2x2 menu is showing. Choosing 사용량/기능 swaps only the
/// dialogue box; the battle scene above it stays put.
enum BattleScreen {
    case root, usage, more, skins, battle

    var message: String {
        switch self {
        case .root:   return "무엇을 할까?"
        case .usage:  return "어떤 한도를 볼까?"
        case .more:   return "어떤 걸 해볼까?"
        case .skins:  return "누구로 바꿀까?"
        case .battle: return "무엇을 할까?"
        }
    }
}

/// One cell of the 2x2 menu. `enabled == false` draws it dimmed and ignores clicks.
struct BattleItem {
    let title: String
    let action: BattleAction
    var enabled = true
}

enum BattleAction {
    case openUsage, openMore, openSkins, openBattle, back
    case tackle                 // 몸통박치기 — animated entirely inside the view
    case pickLimit(String)      // limit `kind`
    case pickSkin(String)       // skin `id`
    case toggleCompact
    case checkUpdate
    case refresh
    case quit
    case none                   // reserved slot, not yet decided
}

final class BattleView: NSView {
    /// Used% of the tracked limit — the same number the menu-bar widget shows.
    /// Re-read from the delegate after a limit switch, so the sprite's HP and Lv
    /// follow the menu-bar widget.
    var usedPercent: Int
    /// The limits available on this account, in display order.
    var limits: [Limit]
    /// Which limit is tracked right now (a `kind`).
    var selectedKind: String
    /// Whether compact mode is on — flips the 좁게 보기/넓게 보기 label.
    var compactOn: Bool
    /// The chosen skin's id, and how many pets so far (gates the shiny).
    var skinID: String
    var petCount: Int

    /// Actions are performed by the app delegate; the view only draws and routes.
    var perform: (BattleAction) -> Void = { _ in }
    /// Called when Escape/back is pressed at the root — closes the panel.
    var onDismiss: () -> Void = {}

    var screen: BattleScreen = .root
    var cursor = 0

    // ── Animation
    private var animTimer: Timer?
    private var tick = 0
    /// Claude's hop. The widget's version is 1px because it lives in a 22px menu
    /// bar; here there is room for a taller, slower arc.
    private var bob: CGFloat = 0
    static let clawdHop: CGFloat = 4          // px at the top of the hop
    /// The bug drifts toward a target, then picks a new one. Interpolating toward
    /// a target (rather than jittering each frame) is what makes it read as
    /// floating instead of vibrating.
    private var bugOffset = NSPoint.zero
    private var bugTarget = NSPoint.zero
    static let bugDriftX: CGFloat = 16        // max px from center, horizontally
    static let bugDriftY: CGFloat = 13        // less vertical room: indicators

    // ── Easter egg: 무당벌레
    /// The enemy's black HP plate, recorded while drawing it (the same trick the
    /// widget's sprite hitbox uses) so mouseDown can hit-test it without
    /// recomputing the indicator layout.
    private var enemyHPRect = NSRect.zero
    /// The skin picker's top-right "뒤로가다" button, recorded while drawing so
    /// mouseDown can hit-test it (the picker has no 2x2 cell for going back).
    private var skinBackRect = NSRect.zero
    private var hpClicks = 0
    /// Purely cosmetic and deliberately not persisted: closing the panel resets
    /// the bug, so finding it again is part of the joke.
    private var ladybug = false
    var bugPalette: [Character: NSColor] { ladybug ? ladybugColors : bugColors }

    /// A transient two-line barker that takes over the dialogue slot when the egg
    /// fires, then expires back to the screen's own message. Two lines because the
    /// beat is a pause and then the reveal — one line would give it all away at once.
    private var flashLines: [String] = []
    private var flashUntil: Date?
    private var flashing: Bool {
        guard let u = flashUntil else { return false }
        return Date() < u
    }

    // ── Shiny sparkle
    /// When the entrance burst started, or nil once it has run. Set on appear and
    /// on switching *to* the shiny, so picking it in the menu replays the effect —
    /// that moment is the payoff for 50 pets and should not pass unmarked.
    private var sparkleStart: Date?
    /// The player's sprite frame, recorded while drawing so the burst can be placed
    /// over it without recomputing the battle-area layout.
    private var playerSpriteRect = NSRect.zero
    var isShiny: Bool { skin(id: skinID).isRare }

    /// The enemy bug's level and HP, rolled fresh each time a battle panel opens
    /// (a new BattleView is built per open). Purely cosmetic — unrelated to the
    /// account's real usage, which only drives the player's side.
    let enemyLevel = Int.random(in: 2...60)
    static let enemyMaxHP = 100
    private var enemyHP = Int.random(in: 20...BattleView.enemyMaxHP)
    var enemyFrac: CGFloat { CGFloat(enemyHP) / CGFloat(Self.enemyMaxHP) }

    // ── 몸통박치기 (tackle)
    /// Frame counter for the attack animation; -1 when idle. Driven by step(), so
    /// the whole sequence runs on the existing 12fps timer.
    private var attackTick = -1
    /// A tackle that cannot land (the bug is down to its last HP) plays the lunge
    /// but never flashes the bug — it just reports the miss.
    private var attackMissed = false
    /// Ticks: 0-2 lunge out and back (one tick per leg, so the swing reads fast),
    /// 3-10 the hit flash (2 blinks).
    private static let lungeEnd = 3
    private static let flashEnd = 11

    /// Claude's lunge toward the upper right, then back.
    private var attackOffset: NSPoint {
        switch attackTick {
        case 0:  return NSPoint(x: 6, y: 5)
        case 1:  return NSPoint(x: 12, y: 10)
        case 2:  return NSPoint(x: 6, y: 5)
        default: return .zero
        }
    }
    /// Retro hit flash: the bug blanks for two ticks, shows for two, twice.
    private var bugHidden: Bool {
        guard !attackMissed, attackTick >= Self.lungeEnd, attackTick < Self.flashEnd else { return false }
        return ((attackTick - Self.lungeEnd) / 2) % 2 == 0
    }
    /// The squeezed-shut face holds for the whole flash, not just the visible frames.
    private var bugHurting: Bool {
        !attackMissed && attackTick >= Self.lungeEnd && attackTick < Self.flashEnd
    }

    /// Start a tackle. Damage is random but never more than half the bug's remaining
    /// HP, so it can never be knocked out; at 1 HP nothing can land and it misses.
    func startTackle() {
        guard attackTick < 0 else { return }        // ignore re-entry mid-swing
        let maxDamage = enemyHP / 2
        attackMissed = maxDamage < 1
        attackTick = 0
        needsDisplay = true
    }

    func startSparkle() {
        guard isShiny else { return }
        sparkleStart = Date()
        needsDisplay = true
    }

    init(frame: NSRect, usedPercent: Int, limits: [Limit], selectedKind: String,
         compactOn: Bool, skinID: String, petCount: Int) {
        self.usedPercent = usedPercent
        self.limits = limits
        self.selectedKind = selectedKind
        self.compactOn = compactOn
        self.skinID = skinID
        self.petCount = petCount
        super.init(frame: frame)
        wantsLayer = true
    }

    /// This account's skin as chosen; and which skins are pickable right now.
    var skinColors: [Character: NSColor] { skin(id: skinID).battleColors }
    func isUnlocked(_ s: ClawdSkin) -> Bool { petCount >= s.unlockPets }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Start/stop the animation with the view's presence on screen, so a closed
    /// panel never keeps a timer (and a retain cycle) alive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animTimer?.invalidate()
        animTimer = nil
        guard window != nil else { return }
        pickBugTarget()
        startSparkle()          // the shiny announces itself on entry; no-op otherwise
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    /// Aim somewhere new, but never near where we already are: a target next to
    /// the current position produces a twitch, not a drift.
    private func pickBugTarget() {
        let rx = Self.bugDriftX, ry = Self.bugDriftY
        for _ in 0..<8 {
            let p = NSPoint(x: .random(in: -rx...rx), y: .random(in: -ry...ry))
            if hypot(p.x - bugOffset.x, p.y - bugOffset.y) > rx * 0.8 { bugTarget = p; return }
        }
        bugTarget = NSPoint(x: -bugOffset.x, y: -bugOffset.y)   // fall back: swing across
    }

    private func step() {
        tick += 1

        // Tackle: advance the swing. Damage lands the moment the flash starts, so
        // the gauge drops in step with the blinking.
        var attacking = false
        if attackTick >= 0 {
            attackTick += 1
            attacking = true
            if attackTick == Self.lungeEnd {
                if attackMissed {
                    flashLines = ["클로드의 공격이", "빗나갔다!"]
                    flashUntil = Date().addingTimeInterval(LADYBUG_FLASH_HOLD)
                    attackTick = -1                  // nothing left to animate
                } else {
                    enemyHP -= Int.random(in: 1...(enemyHP / 2))
                }
            } else if attackTick >= Self.flashEnd {
                attackTick = -1                      // swing over
            }
        }

        // Claude hops in a 4px arc. A sine gives the arc; rounding keeps it on
        // the pixel grid, so the sprite never lands on a half-pixel and blurs.
        let phase = Double(tick % 24) / 24.0
        let newBob = (CGFloat(sin(phase * .pi * 2) * Double(Self.clawdHop))).rounded()

        // Bug: ease toward the target, then choose another once close enough.
        let dx = bugTarget.x - bugOffset.x, dy = bugTarget.y - bugOffset.y
        bugOffset = NSPoint(x: bugOffset.x + dx * 0.085, y: bugOffset.y + dy * 0.085)
        if abs(dx) + abs(dy) < 1.5 { pickBugTarget() }

        // The sparkle animates on its own clock, so it has to force repaints for
        // its whole run — otherwise a still frame (no bob, no drift) would freeze
        // it mid-burst. Clear it when done so we stop repainting for nothing.
        var sparkling = false
        if let s = sparkleStart {
            if Date().timeIntervalSince(s) > SPARKLE_DURATION { sparkleStart = nil }
            else { sparkling = true }
        }

        // The barker expires on a clock too, and its last frame needs one repaint
        // to clear — without this it would linger until the next bob happened to
        // trigger a redraw.
        var flashExpired = false
        if let u = flashUntil, Date() >= u { flashUntil = nil; flashExpired = true }

        // draw(_:) repaints the whole panel (the rounded background makes a
        // partial repaint fiddly), so only ask for one when something moved.
        let moved = newBob != bob || abs(dx) + abs(dy) > 0.05
        bob = newBob
        if moved || sparkling || flashExpired || attacking { needsDisplay = true }
    }

    deinit { animTimer?.invalidate() }

    override var acceptsFirstResponder: Bool { true }

    static let bigFontSize: CGFloat = 17
    static let hpLabelSize: CGFloat = 11
    static let cellH: CGFloat = 32
    let dialogH: CGFloat = cellH * 2 + 8 + 24
    let pad: CGFloat = 12
    let boxBorder: CGFloat = 4
    /// Horizontal breathing room inside each menu cell. Without it the right
    /// column's text sits flush against the container's border.
    ///
    /// These numbers are load-bearing together, alongside BATTLE_W: the longest
    /// label ("사용량 선택" / "색상 커스텀", ~90pt at 16pt) must fit in
    ///   cellWidth - (cellPadX + cursorW) - cellPadX
    /// while the longest message ("어떤 한도를 볼까?", ~136pt) still fits the
    /// left area. Both clear by only a few points — widen the cursor gap or the
    /// padding without also widening the panel and text starts clipping.
    let cellPadX: CGFloat = 12
    let cursorW: CGFloat = 18       // cursor column: ▶ plus the gap before the label
    let menuRatio: CGFloat = 0.60
    static let itemFontSize: CGFloat = 16

    /// The four cells of the current page. 사용량 is built from the account's
    /// real limits, so an account without a scoped (Fable) limit never shows one.
    var items: [BattleItem] {
        switch screen {
        case .root:
            return [
                BattleItem(title: "싸우다", action: .openBattle),
                BattleItem(title: "사용량 선택", action: .openUsage),
                BattleItem(title: "더보기", action: .openMore),
                BattleItem(title: "종료하다", action: .quit),
            ]
        case .battle:
            return [
                BattleItem(title: "몸통박치기", action: .tackle),
                BattleItem(title: "—", action: .none, enabled: false),
                BattleItem(title: "—", action: .none, enabled: false),
                BattleItem(title: "뒤로가다", action: .back),
            ]
        case .usage:
            let order = ["session", "weekly_all", "weekly_scoped"]
            let sorted = limits.sorted {
                (order.firstIndex(of: $0.kind) ?? 9) < (order.firstIndex(of: $1.kind) ?? 9)
            }
            var out = sorted.prefix(3).map {
                BattleItem(title: shortLabel(for: $0), action: .pickLimit($0.kind))
            }
            while out.count < 3 { out.append(BattleItem(title: "—", action: .none, enabled: false)) }
            out.append(BattleItem(title: "뒤로가다", action: .back))
            return out
        case .more:
            return [
                BattleItem(title: compactOn ? "넓게 보기" : "좁게 보기", action: .toggleCompact),
                BattleItem(title: "버전 확인", action: .checkUpdate),
                BattleItem(title: "색상 커스텀", action: .openSkins),
                BattleItem(title: "뒤로가다", action: .back),
            ]
        case .skins:
            return []   // the skin picker draws its own grid, not a 2x2 menu
        }
    }

    /// The six skins, in party order.
    var skinCells: [ClawdSkin] { ALL_SKINS }

    /// The full menu labels ("세션 (5시간)") do not fit a cell, so shorten them
    /// to the period each limit covers.
    private func shortLabel(for l: Limit) -> String {
        switch l.kind {
        case "session":    return "5시간"
        case "weekly_all": return "7일"
        case "weekly_scoped":
            // The scope name is a model name from the API (e.g. "Fable").
            // Transliterate the ones we know; otherwise show what the API gave.
            let ko = ["Fable": "페이블", "Opus": "오퍼스", "Sonnet": "소네트", "Haiku": "하이쿠"]
            let n = l.scopeName ?? "7일"
            return ko[n] ?? n
        default:
            return l.kind
        }
    }

    // The player's indicator carries four rows (name / gauge / numbers / exp),
    // so it must be taller than the enemy's or the numbers collide with the gauge.
    let enemyBoxSize = NSSize(width: 195, height: 44)
    // 64 is about the floor: below ~62 the HP numbers start overlapping the exp
    // bar, since name/gauge hang from the top and numbers/exp stack from the base.
    let playerBoxSize = NSSize(width: 200, height: 64)

    override func draw(_ dirty: NSRect) {
        let r = bounds
        GB_BG.setFill()
        let outer = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        outer.fill()
        GB_INK.setStroke(); outer.lineWidth = 2; outer.stroke()

        // The skin picker takes the whole panel, like the party screen.
        if screen == .skins { drawSkinPicker(); return }

        // Battle area first, dialog box over it: that is what crops Claude's legs.
        drawBattleArea(NSRect(x: r.minX, y: r.minY + dialogH,
                              width: r.width, height: r.height - dialogH))
        drawDialogBox(dialogBox)
    }

    private func drawBattleArea(_ area: NSRect) {
        let enemyBox = NSRect(x: area.minX + 14, y: area.maxY - enemyBoxSize.height - 12,
                              width: enemyBoxSize.width, height: enemyBoxSize.height)
        let playerBox = NSRect(x: area.maxX - playerBoxSize.width - 14, y: area.minY + 6,
                               width: playerBoxSize.width, height: playerBoxSize.height)

        // Sprites are centered in whatever space the indicators leave, so changing
        // an indicator's size moves the sprite with it instead of stranding it.
        // The bug floats around that center; Claude hops in place.
        // bugBase already carries hand-placed shading (D/G/B tones), so it is
        // drawn as-is. battleShaded would re-tone the 'B' body cells by light
        // direction and fight that hand shading.
        // While a tackle lands the bug wears the squeezed-shut face and blinks out
        // entirely on alternating frames — the Gen-2 hit flash.
        let eGrid = bugHurting ? bugHurtBase : bugBase
        let eCell: CGFloat = 4.0
        let eSize = spriteSize(eGrid, cell: eCell)
        let eField = NSRect(x: enemyBox.maxX, y: playerBox.maxY,
                            width: area.maxX - enemyBox.maxX, height: area.maxY - playerBox.maxY)
        if !bugHidden {
            drawSprite(eGrid, origin: NSPoint(x: eField.midX - eSize.width / 2 - 9 + bugOffset.x,
                                              y: eField.midY - eSize.height / 2 - 10 + bugOffset.y),
                       cell: eCell, colors: bugPalette)
        }

        // The dialog box swallowing the lower body is intentional — Gen-2 back
        // sprites are cropped at the waist the same way, so do not "fix" this by
        // raising the sprite. The grid below the crop line is drawn but never seen.
        let pGrid = clawdBackGrid()
        let pCell: CGFloat = 5.8
        let pSize = spriteSize(pGrid, cell: pCell)
        let pField = NSRect(x: area.minX, y: area.minY,
                            width: playerBox.minX - area.minX, height: enemyBox.minY - area.minY)
        // attackOffset lunges Claude toward the upper right during a tackle.
        let pOrigin = NSPoint(x: pField.midX - pSize.width / 2 + attackOffset.x,
                              y: pField.midY - pSize.height / 2 - 45 + bob + attackOffset.y)
        drawSprite(pGrid, origin: pOrigin, cell: pCell, colors: skinColors)
        playerSpriteRect = NSRect(origin: pOrigin, size: pSize)

        drawIndicator(enemyBox, name: BATTLE_ENEMY_NAME, level: enemyLevel,
                      frac: enemyFrac, isPlayer: false)
        let remaining = max(0, min(100, 100 - usedPercent))
        // The ★ rides on the name so it inherits the indicator's layout. The name
        // is the shortest field there, so the extra glyph has room; see
        // docs/battle-ui.md before adding anything wider.
        drawIndicator(playerBox, name: isShiny ? "클로드\(SHINY_MARK)" : "클로드", level: usedPercent,
                      frac: CGFloat(remaining) / 100, isPlayer: true, remaining: remaining)

        // Sparkles last, so they sit over the sprite and the indicators both.
        if let s = sparkleStart, isShiny {
            let t = Date().timeIntervalSince(s) / SPARKLE_DURATION
            drawSparkles(in: playerSpriteRect, t: t, gold: SHINY_GOLD)
        }
    }

    /// Gen-2 indicator: name (larger) + level (smaller) on one baseline, a thin
    /// rectangular gauge, and a frame made of a thick vertical band plus a thin
    /// bottom rule (~5x thinner) ending in a half-arrowhead. The player's is
    /// mirrored, and carries big HP numbers plus a container-less exp bar that
    /// fills right-to-left.
    /// A GB-style half-arrowhead built from stacked pixel rows instead of a smooth
    /// triangle, so its hypotenuse steps like the reference sprite. The tip keeps a
    /// 1px stub rather than a needle point, giving the rounded-off look.
    /// `baseX` is the vertical (base) edge; the tip sits `w` away toward `tipDir`
    /// (+1 = tip to the right, -1 = tip to the left). Rows stack up from `y`.
    private func drawPixelArrow(baseX: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, tipDir: CGFloat) {
        let px: CGFloat = 1.375           // one "pixel" — matches the sprite cell feel
        let rows = max(1, Int((h / px).rounded()))
        let stub: CGFloat = px            // blunt tip: shortest row is 1px wide, not 0
        for r in 0..<rows {
            // Bottom row is full width (w); each row up loses a step, down to the stub.
            let t = CGFloat(r) / CGFloat(rows)
            let rowW = max(stub, w * (1 - t))
            let rowY = y + CGFloat(r) * px
            let rowX = tipDir > 0 ? baseX : baseX - rowW
            NSRect(x: rowX, y: rowY, width: rowW, height: px).fill()
        }
    }

    enum Corner { case bottomLeft, topRight, bottomRight }

    /// Rounds one corner of a filled shape by painting stepped pixel triangles in
    /// the background color — the same staircase look as drawPixelArrow, but
    /// subtractive. `x,y` is the corner origin; `size` is the band thickness so the
    /// notch scales with it. Must run inside the same non-antialiased context, and
    /// the current fill color is overwritten (caller re-sets ink if needed).
    private func drawCornerNotch(x: CGFloat, y: CGFloat, size: CGFloat, corner: Corner) {
        let px: CGFloat = 1.375
        let steps = max(1, Int((size * 0.5 / px).rounded()))   // notch ~half the thickness
        GB_BG.setFill()
        for s in 0..<steps {
            let cut = CGFloat(steps - s) * px      // widest cut at the very corner
            let off = CGFloat(s) * px
            switch corner {
            case .bottomLeft:
                NSRect(x: x, y: y + off, width: cut, height: px).fill()
            case .topRight:
                NSRect(x: x + size - cut, y: y - off - px, width: cut, height: px).fill()
            case .bottomRight:
                NSRect(x: x + size - cut, y: y + off, width: cut, height: px).fill()
            }
        }
    }

    /// 계단식으로 안쪽 코너를 채운다(둥근 안쪽 모서리). x,y는 코너 기준점,
    /// 좌측 위에서 우측 아래로 내려오는 계단을 GB_INK로 그린다.
    private func drawCornerFill(x: CGFloat, y: CGFloat, size: CGFloat) {
        let px: CGFloat = 1.375
        let steps = max(1, Int((size * 0.5 / px).rounded()))
        GB_INK.setFill()
        for s in 0..<steps {
            let w = CGFloat(steps - s) * px       // 위로 갈수록 넓게
            let rowY = y + CGFloat(s) * px         // 코너에서 아래로 쌓기
            NSRect(x: x, y: rowY, width: w, height: px).fill()
        }
    }


    private func drawIndicator(_ box: NSRect, name: String, level: Int, frac: CGFloat,
                               isPlayer: Bool, remaining: Int = 0) {
        let title = NSMutableAttributedString(string: name,
            attributes: [.font: pixelFont(18), .foregroundColor: GB_INK])
        title.append(NSAttributedString(string: ":L\(level)",
            attributes: [.font: pixelFont(14), .foregroundColor: GB_INK]))
        let ts = title.size()

        let bandW: CGFloat = 9.5
        let lineH: CGFloat = 2       // bottom rule; integer so both indicators' rules
                                     // land on the same pixel weight (no subpixel drift)
        let arrowW: CGFloat = 13.75  // 1.25× the old 11
        let arrowH: CGFloat = 8
        let lineY = box.minY
        // Player-only: a black connector strip where the right vertical band meets
        // the HP bar (top) and the exp/arrow line (bottom). Each strip is this wide
        // and overlays the bar, so both gauges lose this much of their full width.
        let junctionW: CGFloat = 5

        let unitH: CGFloat = 12
        let unitY = box.maxY - ts.height - unitH - 2
        let labelW: CGFloat = 28
        let unit = isPlayer
            ? NSRect(x: box.minX + 8, y: unitY, width: box.width - 8 - bandW + 1, height: unitH)
            : NSRect(x: box.minX + bandW - 1, y: unitY, width: box.width - bandW - 3, height: unitH)

        // The name starts where the gauge starts — i.e. just past the black
        // "HP:" cap, above the boundary between the cap and the bar. labelW is
        // the cap's width, so unit.minX + labelW is the gauge's left edge.
        let gaugeStartX = unit.minX + labelW
        title.draw(at: NSPoint(x: gaugeStartX, y: box.maxY - ts.height))

        // The enemy's plate is the easter egg's hit target; remember where it
        // landed so mouseDown does not have to redo this layout.
        if !isPlayer { enemyHPRect = unit }

        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        GB_INK.setFill(); unit.fill()
        // The enemy's track stops short, leaving the thick black cap on its right.
        // The player's right margin is junctionW: the unit is black full-height, so
        // that margin reads as the top connector strip, and the gauge stops before it.
        let trackR: CGFloat = isPlayer ? junctionW : 8   // enemy cap doubled (was 4)
        // The track background is GB_BG, not white, so the empty part of the gauge
        // and the padding above/below it read as "no track" — the colored gauge
        // just floats on the panel. It flushes to the unit's TOP so no black rule
        // shows above; a thin black rule remains below. The colored gauge inside is
        // 0.75× the old height (9→6.75) and centered in the track.
        let trackX = unit.minX + labelW
        let trackW = unit.width - labelW - trackR
        let track = NSRect(x: trackX, y: unit.minY + 1.5,
                           width: trackW, height: unitH - 1.5)   // top flush, ~1.5 below
        GB_BG.setFill(); track.fill()
        if frac > 0 {
            let gaugeH: CGFloat = (unitH - 3) * 0.75 * 0.75   // thinned once more (0.75×)
            gaugeColor(frac).setFill()
            NSRect(x: track.minX, y: track.minY + (track.height - gaugeH) / 2,
                   width: track.width * frac, height: gaugeH).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        let hpAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(Self.hpLabelSize),
                                                     .foregroundColor: GB_YELLOW]
        let hpLabel = "HP:" as NSString
        let hs = hpLabel.size(withAttributes: hpAttr)
        hpLabel.draw(at: NSPoint(x: unit.minX + 5, y: unit.minY + (unitH - hs.height) / 2),
                     withAttributes: hpAttr)

        if isPlayer {
            let numAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(20), .foregroundColor: GB_INK]
            let num = "\(remaining)/ 100" as NSString
            let ns = num.size(withAttributes: numAttr)
            num.draw(at: NSPoint(x: box.maxX - bandW - 6 - ns.width, y: unit.minY - ns.height - 1),
                     withAttributes: numAttr)
        }

        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        GB_INK.setFill()
        if isPlayer {
            let pBandX = box.maxX - bandW
            NSRect(x: pBandX, y: lineY, width: bandW, height: unit.maxY - lineY).fill()
            let tipX = box.minX - 6
            NSRect(x: tipX + arrowW, y: lineY, width: box.maxX - (tipX + arrowW), height: lineH).fill()
            // Tip points left; base edge sits at tipX + arrowW.
            drawPixelArrow(baseX: tipX + arrowW, y: lineY, w: arrowW, h: arrowH, tipDir: -1)
            // Round the band's outer (right) corners, top and bottom.
            drawCornerNotch(x: pBandX, y: unit.maxY, size: bandW, corner: .topRight)
            drawCornerNotch(x: pBandX, y: lineY, size: bandW, corner: .bottomRight)
            GB_INK.setFill()   // notch left GB_BG selected; restore for the exp bar path below
            // Bottom connector strip: black, junctionW wide, arrowhead-tall, flush to
            // the band's left edge. Overlays the line/exp area at the junction.
            NSRect(x: pBandX - junctionW, y: lineY, width: junctionW, height: arrowH).fill()
            let expX = tipX + arrowW + 2
            // Exp bar total width loses junctionW so its right edge sits flush
            // against the strip's left edge (pBandX - junctionW).
            let exp = NSRect(x: expX, y: lineY + lineH + 2,
                             width: (box.maxX - bandW) - expX - junctionW, height: 4)
            GB_EXP.setFill()
            NSRect(x: exp.maxX - exp.width * 0.55, y: exp.minY,
                   width: exp.width * 0.55, height: exp.height).fill()
        } else {
            // Enemy bracket: a vertical band on the LEFT (outside the HP bar so it
            // never covers the "HP:" cap), a bottom rule, and an arrowhead on the
            // right — joined as one right-angled ⌐ shape.
            let bandGap: CGFloat = 4
            let eBandW = bandW * 0.75           // thinner band (0.75×)
            let eBandH = (unit.maxY - lineY) * 1.25   // taller band (1.25×)
            let bandX = box.minX - bandGap      // original left position (clears "HP:")
            let eBandBottom = (unit.maxY - eBandH).rounded()   // pixel-align the rule
            // Arrowhead base aligns with the HP bar's right edge (unit.maxX): the
            // triangle sits directly under the gauge's end, not past the box.
            let endX = unit.maxX + arrowW
            // Bottom rule spans from ruleX to the arrowhead's base. ruleX is the
            // horizontal start of the rule ONLY — decoupled from bandX so the rule
            // can slide right to meet the band's right edge without dragging the
            // vertical band with it. Draw the rule FIRST at eBandBottom with pure
            // lineH, then the band stops just above it (its bottom == rule's top) so
            // the band never stacks onto the rule and thickens it.
            // Rule and band share bandX, so the band, rule, and stepped notch all
            // align on the same left edge — no overhang. ruleX stays separate only
            // so the rule's start can be nudged later without moving the band.
            let ruleX = bandX + 6.5
            NSRect(x: ruleX, y: eBandBottom + 1, width: (endX - arrowW) - ruleX, height: lineH).fill()
            NSRect(x: bandX, y: eBandBottom + lineH,
                   width: eBandW, height: eBandH - lineH).fill()
            // Tip points right; base edge sits at endX - arrowW, on the same rule.
            drawPixelArrow(baseX: endX - arrowW, y: eBandBottom + 1, w: arrowW, h: arrowH, tipDir: 1)
            // Restore the stepped, rounded bottom-left corner of the band.
            drawCornerNotch(x: bandX, y: eBandBottom + lineH, size: eBandW, corner: .bottomLeft)
            drawCornerFill(x: bandX + eBandW, y: eBandBottom + lineH, size: eBandW + 3)
            GB_INK.setFill()
        }
        // Restore, or the dialog box's curves drawn next come out jagged too.
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    var dialogBox: NSRect {
        NSRect(x: bounds.minX + pad, y: bounds.minY + pad,
               width: bounds.width - pad * 2, height: dialogH - pad * 2)
    }
    var menuBox: NSRect {
        let w = dialogBox.width * menuRatio
        return NSRect(x: dialogBox.maxX - w, y: dialogBox.minY, width: w, height: dialogBox.height)
    }
    var menuInner: NSRect { menuBox.insetBy(dx: boxBorder, dy: boxBorder) }

    /// The four cells divide menuInner exactly, with no gaps between them.
    /// (Text is inset within each cell; see cellPadX.)
    func itemRect(_ i: Int) -> NSRect {
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        let w = menuInner.width / 2, h = menuInner.height / 2
        return NSRect(x: menuInner.minX + col * w, y: menuInner.maxY - (row + 1) * h,
                      width: w, height: h)
    }

    // ── Skin picker (party-style screen)

    /// A locked skin shows as a flat gray silhouette so its color stays a surprise.
    private var lockedColors: [Character: NSColor] {
        ["K": GB_INK, "B": rgb(0x6A, 0x66, 0x72), "D": rgb(0x6A, 0x66, 0x72), "L": rgb(0x6A, 0x66, 0x72)]
    }

    /// Area the 3x2 skin grid fills, below the title row.
    private var skinGrid: NSRect {
        let m: CGFloat = 12, titleH: CGFloat = 30
        return NSRect(x: bounds.minX + m, y: bounds.minY + m,
                      width: bounds.width - m * 2, height: bounds.height - m * 2 - titleH)
    }
    func skinRect(_ i: Int) -> NSRect {
        let colsN = 3, rowsN = 2, gap: CGFloat = 8
        let cw = (skinGrid.width - gap * CGFloat(colsN - 1)) / CGFloat(colsN)
        let ch = (skinGrid.height - gap * CGFloat(rowsN - 1)) / CGFloat(rowsN)
        let col = i % colsN, row = i / colsN
        return NSRect(x: skinGrid.minX + CGFloat(col) * (cw + gap),
                      y: skinGrid.maxY - CGFloat(row + 1) * ch - CGFloat(row) * gap,
                      width: cw, height: ch)
    }

    private func drawSkinPicker() {
        let titleAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(Self.itemFontSize),
                                                        .foregroundColor: GB_INK]
        let title = screen.message as NSString
        let th = title.size(withAttributes: titleAttr).height
        title.draw(at: NSPoint(x: bounds.minX + 18, y: bounds.maxY - 12 - th), withAttributes: titleAttr)

        // Top-right back button — clickable (and still Esc-able). The picker has
        // no 2x2 grid, so this is the in-UI way out.
        let back = "◀ 뒤로가다" as NSString
        let backAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(13), .foregroundColor: GB_INK]
        let bs = back.size(withAttributes: backAttr)
        let backOrigin = NSPoint(x: bounds.maxX - 18 - bs.width, y: bounds.maxY - 12 - bs.height)
        back.draw(at: backOrigin, withAttributes: backAttr)
        // Pad the hit area so the whole word is comfortably clickable.
        skinBackRect = NSRect(x: backOrigin.x - 6, y: backOrigin.y - 4,
                              width: bs.width + 12, height: bs.height + 8)

        let miniGrid = spriteGrids[.healthy]![0]
        let miniCell: CGFloat = 2.6
        let miniSize = spriteSize(miniGrid, cell: miniCell)

        for (i, s) in skinCells.enumerated() {
            let cell = skinRect(i)
            let selected = (s.id == skinID)
            let focused = (i == cursor)
            let unlocked = isUnlocked(s)

            let boxPath = NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6)
            (selected ? NSColor.white : GB_BG).setFill(); boxPath.fill()
            GB_INK.setStroke(); boxPath.lineWidth = focused ? 3 : 1.5; boxPath.stroke()

            drawSprite(miniGrid,
                       origin: NSPoint(x: cell.midX - miniSize.width / 2, y: cell.maxY - miniSize.height - 12),
                       cell: miniCell, colors: unlocked ? s.battleColors : lockedColors)

            let name = (unlocked ? s.name : "？？？") as NSString
            let nameAttr: [NSAttributedString.Key: Any] = [
                .font: pixelFont(14),
                .foregroundColor: unlocked ? GB_INK : GB_INK.withAlphaComponent(0.4)]
            let ns = name.size(withAttributes: nameAttr)
            name.draw(at: NSPoint(x: cell.midX - ns.width / 2, y: cell.minY + 9), withAttributes: nameAttr)

            if selected {
                ("✓" as NSString).draw(at: NSPoint(x: cell.minX + 8, y: cell.maxY - 22),
                                       withAttributes: [.font: pixelFont(15), .foregroundColor: GB_INK])
            }
            // A rare skin keeps a gold ★ in its cell once earned — opposite corner
            // from the ✓, so a selected shiny shows both without them colliding.
            if s.isRare && unlocked {
                (SHINY_MARK as NSString).draw(at: NSPoint(x: cell.maxX - 22, y: cell.maxY - 22),
                                              withAttributes: [.font: pixelFont(15),
                                                               .foregroundColor: SHINY_GOLD])
            }
        }
    }

    private func drawDialogBox(_ box: NSRect) {
        GB_BG.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.fill()
        GB_INK.setStroke(); path.lineWidth = 3; path.stroke()
        let inner = NSBezierPath(roundedRect: box.insetBy(dx: 4, dy: 4), xRadius: 4, yRadius: 4)
        GB_INK.setStroke(); inner.lineWidth = 1; inner.stroke()

        GB_BG.setFill()
        let mPath = NSBezierPath(roundedRect: menuBox, xRadius: 6, yRadius: 6)
        mPath.fill()
        GB_INK.setStroke(); mPath.lineWidth = 3; mPath.stroke()
        let mInner = NSBezierPath(roundedRect: menuBox.insetBy(dx: 4, dy: 4), xRadius: 4, yRadius: 4)
        GB_INK.setStroke(); mInner.lineWidth = 1; mInner.stroke()

        let font = pixelFont(Self.itemFontSize)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: GB_INK]

        if flashing {
            // The barker uses both menu rows' worth of height, so it is centered on
            // the pair of baselines rather than on the top row alone.
            let lineH = ("가" as NSString).size(withAttributes: attr).height
            let gap: CGFloat = 4
            let block = lineH * CGFloat(flashLines.count) + gap * CGFloat(flashLines.count - 1)
            let midY = (itemRect(0).midY + itemRect(2).midY) / 2
            var y = midY + block / 2 - lineH
            for line in flashLines {
                (line as NSString).draw(at: NSPoint(x: box.minX + 16, y: y), withAttributes: attr)
                y -= lineH + gap
            }
        } else {
            // The message sits on the same baseline as the menu's top row, not the
            // box's vertical center, so the two columns read as one line of text.
            let msg = screen.message as NSString
            let mh = msg.size(withAttributes: attr).height
            msg.draw(at: NSPoint(x: box.minX + 16, y: itemRect(0).midY - mh / 2), withAttributes: attr)
        }

        let dim: [NSAttributedString.Key: Any] = [.font: font,
                                                  .foregroundColor: GB_INK.withAlphaComponent(0.30)]
        for (i, item) in items.enumerated() {
            let cell = itemRect(i)
            let a = item.enabled ? attr : dim
            let title = item.title as NSString
            let ih = title.size(withAttributes: a).height
            let ty = cell.midY - ih / 2
            // The cursor lives in the left padding, so the text always starts at
            // the same x whether or not this cell is selected.
            title.draw(at: NSPoint(x: cell.minX + cellPadX + cursorW, y: ty), withAttributes: a)
            if i == cursor && item.enabled {
                ("▶" as NSString).draw(at: NSPoint(x: cell.minX + cellPadX - 2, y: ty),
                                       withAttributes: attr)
            }
        }
    }

    // MARK: - Interaction

    /// Move the cursor onto the first selectable cell at or after `from`.
    private func firstEnabled(from: Int) -> Int {
        let all = items
        if all.indices.contains(from), all[from].enabled { return from }
        return all.firstIndex(where: { $0.enabled }) ?? 0
    }

    /// Columns in the current screen's grid: the skin picker is 3-wide, the menus 2.
    private var cols: Int { screen == .skins ? 3 : 2 }
    private var cellCount: Int { screen == .skins ? skinCells.count : items.count }

    func go(to screen: BattleScreen) {
        self.screen = screen
        switch screen {
        case .usage:
            // Start the cursor on the limit already being tracked.
            cursor = items.firstIndex {
                if case .pickLimit(let k) = $0.action { return k == selectedKind }
                return false
            } ?? firstEnabled(from: 0)
        case .skins:
            // Start on the skin already worn.
            cursor = skinCells.firstIndex { $0.id == skinID } ?? 0
        default:
            cursor = firstEnabled(from: 0)
        }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        var next = cursor
        let c = cols
        switch e.keyCode {
        case 126: if cursor - c >= 0 { next = cursor - c }                  // ↑
        case 125: if cursor + c < cellCount { next = cursor + c }           // ↓
        case 123: if cursor % c != 0 { next = cursor - 1 }                  // ←
        case 124: if cursor % c != c - 1 && cursor + 1 < cellCount { next = cursor + 1 }  // →
        case 36, 76: activate(); return                                     // Enter
        case 53:                                                            // Esc
            if screen == .root { onDismiss() } else { go(to: .root) }
            return
        default: super.keyDown(with: e); return
        }
        // In the menus, skip disabled cells; in the picker every cell is landable.
        if screen == .skins || (items.indices.contains(next) && items[next].enabled) {
            cursor = next
        }
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) { hover(e) }

    override func mouseDown(with e: NSEvent) {
        if tapEnemyHP(e) { return }
        let p = convert(e.locationInWindow, from: nil)
        // The skin picker's back button leaves the picker — same as Esc.
        if screen == .skins && skinBackRect.contains(p) { go(to: .root); return }
        hover(e)
        // A click only fires the cell it actually landed in. activate() runs off
        // the cursor, which suits the keyboard (arrows move it, Enter fires it) —
        // but for the mouse the cursor may be parked on a cell far from the click,
        // so clicking the message area or empty space would otherwise trigger it.
        let onCell = (screen == .skins)
            ? skinCells.indices.contains { skinRect($0).contains(p) }
            : items.indices.contains { itemRect($0).contains(p) && items[$0].enabled }
        if onCell { activate() }
    }

    /// Easter egg. The enemy's HP plate sits in the battle area, where no menu
    /// cell can claim the click, so counting taps here steals nothing.
    /// The skin picker replaces the whole panel, so the plate is not on screen
    /// then and the stale rect must not be hit-tested.
    private func tapEnemyHP(_ e: NSEvent) -> Bool {
        guard screen != .skins else { return false }
        let p = convert(e.locationInWindow, from: nil)
        guard enemyHPRect.contains(p) else { return false }

        hpClicks += 1
        if hpClicks >= LADYBUG_CLICKS {
            hpClicks = 0
            ladybug.toggle()
            flashLines = ladybug
                ? ["..... 오잉?!", "버그의 상태가.....!"]
                : ["..... 어라?", "원래대로 돌아왔다!"]
            flashUntil = Date().addingTimeInterval(LADYBUG_FLASH_HOLD)
            needsDisplay = true
        }
        return true
    }

    private func hover(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if screen == .skins {
            for i in skinCells.indices where skinRect(i).contains(p) {
                if cursor != i { cursor = i; needsDisplay = true }
            }
            return
        }
        let all = items
        for i in all.indices where itemRect(i).contains(p) && all[i].enabled {
            if cursor != i { cursor = i; needsDisplay = true }
        }
    }

    private func activate() {
        if screen == .skins {
            guard skinCells.indices.contains(cursor) else { return }
            let s = skinCells[cursor]
            if isUnlocked(s) { perform(.pickSkin(s.id)) }   // locked ⇒ no-op
            return
        }
        let all = items
        guard all.indices.contains(cursor), all[cursor].enabled else { return }
        switch all[cursor].action {
        case .openUsage:  go(to: .usage)
        case .openMore:   go(to: .more)
        case .openSkins:  go(to: .skins)
        case .openBattle: go(to: .battle)
        case .tackle:     startTackle()
        case .back:       go(to: .root)
        case .none:      break
        default:         perform(all[cursor].action)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}

/// Borderless panels do not become key by default, which would leave the panel
/// unable to take the Escape key.
final class BattlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
