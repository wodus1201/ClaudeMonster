import Cocoa
import CoreText

// ── 기술 검증 스파이크 (2차) ────────────────────────────────────────────────
// 메뉴바 아이템을 누르면 게임보이 컬러풍 배틀 화면이 내려온다.
// NSPopover가 아니라 테두리 없는 NSPanel — 팝오버는 화살표/시스템 재질을 벗길 수 없다.
//
// 실기능은 없다. 검증 대상:
//   레이아웃 비율 / 스프라이트 배치 / GBC풍 HP 인디케이터 / 제한 팔레트 셰이딩
//
// --dump <path> 로 실행하면 창을 띄우지 않고 PNG로 저장한다.
//
// 리포 루트에서 빌드/실행할 것 (폰트를 상대경로로 읽는다):
//   swiftc -O prototypes/battle_spike.swift -o /tmp/battle_spike && /tmp/battle_spike

let FONT_PATH = "fonts/neodgm.ttf"
let PIXEL_FONT_NAME = "NeoDunggeunmo"

func registerPixelFont() {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: FONT_PATH) as CFURL, .process, nil)
}
func pixelFont(_ size: CGFloat) -> NSFont {
    NSFont(name: PIXEL_FONT_NAME, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
}

// MARK: - 팔레트
// GBC는 스프라이트당 3색 + 투명이 한계였다. 그 제약을 그대로 흉내낸다:
// 스프라이트마다 (하이라이트 / 기본 / 그림자) 3톤 + 검은 외곽선.

let GB_BG   = NSColor(white: 0.90, alpha: 1)      // 메뉴바 위젯 알약 배경과 동일
let GB_INK  = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)

let HP_GREEN  = NSColor(srgbRed: 0x38/255, green: 0xD0/255, blue: 0x30/255, alpha: 1)
let HP_ORANGE = NSColor(srgbRed: 0xF8/255, green: 0xA8/255, blue: 0x28/255, alpha: 1)
let HP_RED    = NSColor(srgbRed: 0xE8/255, green: 0x30/255, blue: 0x30/255, alpha: 1)
let EXP_BLUE  = NSColor(srgbRed: 0x40/255, green: 0x90/255, blue: 0xE8/255, alpha: 1)
let HP_YELLOW = NSColor(srgbRed: 0xF8/255, green: 0xD0/255, blue: 0x28/255, alpha: 1)

func hpColor(_ frac: CGFloat) -> NSColor {
    if frac >= 0.5 { return HP_GREEN }
    if frac >= 0.2 { return HP_ORANGE }
    return HP_RED
}

// 클로드: Claude 오렌지 3톤
let clawdColors: [Character: NSColor] = [
    "K": GB_INK,
    "L": NSColor(srgbRed: 0xE8/255, green: 0x9A/255, blue: 0x74/255, alpha: 1),  // 하이라이트
    "B": NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1),  // 기본
    "D": NSColor(srgbRed: 0xA6/255, green: 0x47/255, blue: 0x2E/255, alpha: 1),  // 그림자
    "S": NSColor(srgbRed: 0x7A/255, green: 0x33/255, blue: 0x22/255, alpha: 1),  // 이음새
]

// 버그: 초록 3톤 + 눈
let bugColors: [Character: NSColor] = [
    "K": GB_INK,
    "L": NSColor(srgbRed: 0x86/255, green: 0xD0/255, blue: 0x8E/255, alpha: 1),
    "B": NSColor(srgbRed: 0x5A/255, green: 0xA8/255, blue: 0x6A/255, alpha: 1),
    "D": NSColor(srgbRed: 0x2E/255, green: 0x6B/255, blue: 0x3E/255, alpha: 1),
    "W": NSColor.white,
    "R": NSColor(srgbRed: 0xD8/255, green: 0x40/255, blue: 0x38/255, alpha: 1),  // 글리치 붉은 점
]

// MARK: - 실루엣 + 셰이딩
// 실루엣은 한 벌만 두고, 톤은 규칙으로 입힌다. 앞모습 그리드를 고쳐도
// 뒷모습/아이콘이 자동으로 따라오게 하려는 것 (원본 앱의 설계와 같은 이유).

let clawdBase: [String] = [
    ".....KBBBBBBBBK.....",
    "....KBKBBBBBBKBK....",
    "..KBBBBBBBBBBBBBBK..",
    "..KBBBBBBBBBBBBBBK..",
    "..KBBBBBBBBBBBBBBK..",
    "..KBBBBBBBBBBBBBBK..",
    "..KBBBBBBBBBBBBBBK..",
    "KKBBBBBBBBBBBBBBBBKK",
    "KKBBBBBBBBBBBBBBBBKK",
    "..KBBBBBBBBBBBBBBK..",
    "..KBBBBBBBBBBBBBBK..",
    "..KBBBBBBBBBBBBBBK..",
    "...KB..BK..KB..BK...",
    "...KB..BK..KB..BK...",
]

let bugBase: [String] = [
    "....K..........K....",
    ".....K........K.....",
    "....KKKKKKKKKKKK....",
    "...KBBBBBBBBBBBBK...",
    "...KBBWWBBBBWWBBK...",
    "...KBBWKBBBBKWBBK...",
    "...KBBBBBBBBBBBBK...",
    "...KKKKKKKKKKKKKK...",
    ".KKKKKKKKKKKKKKKKKK.",
    ".KBBRRBBBBBBBBRRBBK.",
    ".KBBBBBBBBBBBBBBBBK.",
    ".KBBRRBBBBBBBBRRBBK.",
    ".KBBBBBBBBBBBBBBBBK.",
    ".KKKKKKKKKKKKKKKKKK.",
    "..K..K........K..K..",
    ".K...K........K...K.",
    "K....K........K....K",
]

/// 광원은 왼쪽 위. 몸통('B') 각 칸의 밝기를 "행 안에서의 가로 위치 + 전체에서의
/// 세로 위치"를 섞은 대각선 그라데이션으로 정하고, 톤이 갈리는 경계에서만
/// 체커보드로 두 톤을 섞는다(디더링).
///
/// 열 단위로 디더링하면 세로 줄무늬가 생겨 얼룩처럼 보인다. 경계에서만 섞어야
/// 색 수를 늘리지 않고도 곡면처럼 읽힌다 — 그 시절 스프라이트가 쓰던 방식.
func shaded(_ grid: [String], flatten: Bool = false) -> [String] {
    let rows = grid.count
    return grid.enumerated().map { (r, line) -> String in
        var chars = Array(line)
        let bodyIdx = chars.indices.filter { chars[$0] == "B" }
        guard let first = bodyIdx.first, let last = bodyIdx.last, last > first else { return line }

        for i in bodyIdx {
            let u = Double(i - first) / Double(last - first)      // 0=왼쪽, 1=오른쪽
            let v = Double(r) / Double(max(rows - 1, 1))          // 0=위,   1=아래
            // 납작한 몸(벌레 등껍질)은 세로 영향을 줄여 평평하게 보이게 한다.
            let t = flatten ? (0.75 * u + 0.25 * v) : (0.55 * u + 0.45 * v)
            let dither = (r + i) % 2 == 0                          // 체커 위상

            switch t {
            case ..<0.26:            chars[i] = "L"
            case ..<0.34:            chars[i] = dither ? "L" : "B"  // 빛 → 기본
            case ..<0.62:            chars[i] = "B"
            case ..<0.70:            chars[i] = dither ? "D" : "B"  // 기본 → 그늘
            default:                 chars[i] = "D"
            }
        }
        return String(chars)
    }
}

/// 클로드 뒷모습: 얼굴이 없고 등 한가운데에 이음새가 보인다.
func clawdBackGrid() -> [String] {
    var g = shaded(clawdBase)
    for r in 4...9 {
        var row = Array(g[r])
        if row[10] != "K" { row[10] = "S" }
        g[r] = String(row)
    }
    return g
}

func bugGrid() -> [String] { shaded(bugBase, flatten: true) }

/// 픽셀 그리드를 안티앨리어싱 없이 그린다. row 0 = 맨 위.
func drawSprite(_ grid: [String], origin: NSPoint, cell: CGFloat, colors: [Character: NSColor]) {
    guard let ctx = NSGraphicsContext.current else { return }
    ctx.saveGraphicsState()
    ctx.shouldAntialias = false
    let rows = grid.count
    for (r, line) in grid.enumerated() {
        for (c, ch) in line.enumerated() {
            guard let color = colors[ch] else { continue }
            color.setFill()
            NSRect(x: origin.x + CGFloat(c) * cell,
                   y: origin.y + CGFloat(rows - 1 - r) * cell,
                   width: cell, height: cell).fill()
        }
    }
    ctx.restoreGraphicsState()
}

func spriteSize(_ grid: [String], cell: CGFloat) -> NSSize {
    NSSize(width: CGFloat(grid[0].count) * cell, height: CGFloat(grid.count) * cell)
}

// MARK: - 상태 (표시용 더미)

enum Screen { case root, usage }
let ROOT_ITEMS  = ["사용량 선택", "색상 커스텀", "간결 모드", "종료"]
let USAGE_ITEMS = ["5시간", "주간", "Fable", "뒤로"]

let PLAYER_NAME = "클로드"
let ENEMY_NAME  = "버그"
let ENEMY_LEVEL = 50
let ENEMY_HP_FRAC: CGFloat = 1

// MARK: - 배틀 화면

final class BattleView: NSView {
    var screen: Screen = .root
    var cursor = 0
    var usedPercent: Int
    var onQuit: () -> Void = {}

    init(frame: NSRect, usedPercent: Int) {
        self.usedPercent = usedPercent
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var items: [String] { screen == .root ? ROOT_ITEMS : USAGE_ITEMS }
    var message: String { screen == .root ? "무엇을 할까?" : "어떤 한도를 볼까?" }
    override var acceptsFirstResponder: Bool { true }

    // 캡처 기준 타이포 체계: 이름/숫자/메뉴/메시지가 전부 같은 큰 크기,
    // 작은 것은 노란 "HP:" 라벨 하나뿐이다. (NeoDunggeunmo는 단일 weight라
    // 굵기 차이는 크기로 표현한다.)
    static let bigFontSize: CGFloat = 17
    static let hpLabelSize: CGFloat = 11

    // 2x2 셀이 여백 없이 딱 맞는 높이에서 역산 (큰 폰트에 맞춰 셀도 키움)
    static let cellH: CGFloat = 32
    let dialogH: CGFloat = cellH * 2 + 8 + 24     // = 96
    let pad: CGFloat = 12
    let boxBorder: CGFloat = 4

    // HP 인디케이터 박스 크기.
    // 플레이어 쪽은 이름/게이지/숫자/경험치 네 줄이 들어가므로 더 높아야 한다 —
    // 상대와 같은 높이를 주면 숫자가 게이지를 침범한다.
    let enemyBoxSize = NSSize(width: 195, height: 44)
    let playerBoxSize = NSSize(width: 200, height: 72)

    override func draw(_ dirty: NSRect) {
        let r = bounds
        GB_BG.setFill()
        let outer = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        outer.fill()
        GB_INK.setStroke(); outer.lineWidth = 2; outer.stroke()

        // 배틀 영역을 먼저 그린다 → 대화상자가 그 위를 덮으므로, 아래로 넘친
        // 클로드의 하반신은 자연스럽게 잘린다 (원작과 같은 구도).
        drawBattleArea(NSRect(x: r.minX, y: r.minY + dialogH,
                              width: r.width, height: r.height - dialogH))
        drawDialogBox(dialogBox)
    }

    // ── 배틀 영역
    private func drawBattleArea(_ area: NSRect) {
        let enemyBox = NSRect(x: area.minX + 14, y: area.maxY - enemyBoxSize.height - 12,
                              width: enemyBoxSize.width, height: enemyBoxSize.height)
        // 내 인디케이터는 하단 레터박스에 살짝 패딩만 두고 붙는다 (캡처와 동일).
        let playerBox = NSRect(x: area.maxX - playerBoxSize.width - 14, y: area.minY + 6,
                               width: playerBoxSize.width, height: playerBoxSize.height)

        // 상대 스프라이트: 인디케이터가 차지하지 않은 공간(오른쪽 위)의 정중앙에서
        // 살짝 왼쪽 아래로. 원작도 정확한 중앙이 아니라 화면 안쪽을 향해 있다.
        let eGrid = bugGrid()
        let eCell: CGFloat = 4.4
        let eSize = spriteSize(eGrid, cell: eCell)
        let eField = NSRect(x: enemyBox.maxX, y: playerBox.maxY,
                            width: area.maxX - enemyBox.maxX, height: area.maxY - playerBox.maxY)
        drawSprite(eGrid,
                   origin: NSPoint(x: eField.midX - eSize.width / 2 - 9,
                                   y: eField.midY - eSize.height / 2 - 10),
                   cell: eCell, colors: bugColors)

        // 내 스프라이트: 왼쪽 아래 공간의 가로 정중앙. 아래로 내려 하반신이
        // 대화상자에 가리게 한다 (배틀 영역을 먼저 그리고 대화상자가 덮는다).
        let pGrid = clawdBackGrid()
        let pCell: CGFloat = 5.8
        let pSize = spriteSize(pGrid, cell: pCell)
        let pField = NSRect(x: area.minX, y: area.minY,
                            width: playerBox.minX - area.minX, height: enemyBox.minY - area.minY)
        drawSprite(pGrid,
                   origin: NSPoint(x: pField.midX - pSize.width / 2,
                                   y: pField.midY - pSize.height / 2 - 45),
                   cell: pCell, colors: clawdColors)

        drawHPBox(enemyBox, name: ENEMY_NAME, level: ENEMY_LEVEL,
                  frac: ENEMY_HP_FRAC, isPlayer: false)
        let remaining = max(0, min(100, 100 - usedPercent))
        drawHPBox(playerBox, name: PLAYER_NAME, level: usedPercent,
                  frac: CGFloat(remaining) / 100, isPlayer: true, remaining: remaining)
    }

    /// 원작(2세대) 인디케이터.
    /// - 이름이 레벨(:Ln)보다 조금 크다 (같은 베이스라인에 두 크기)
    /// - HP 게이지는 얇은 직사각형 (캡슐 아님)
    /// - 프레임: 굵은 세로 띠 + 얇은 아래 선 (띠가 선보다 ~5배 두껍다).
    ///   상대는 왼쪽 띠 + 아래 선 오른쪽 끝의 반쪽 화살촉,
    ///   나는 좌우반전 — 오른쪽 띠(게이지가 직각으로 붙음) + 왼쪽 끝 화살촉.
    /// - 나: 큰 HP 숫자, 그리고 컨테이너 없는 경험치 바(우→좌 채움, 범위는
    ///   화살촉부터 오른쪽 띠까지)가 아래 선 살짝 위에 놓인다.
    private func drawHPBox(_ box: NSRect, name: String, level: Int, frac: CGFloat,
                           isPlayer: Bool, remaining: Int = 0) {
        // 이름 > 레벨 폰트 위계
        let title = NSMutableAttributedString(string: name,
            attributes: [.font: pixelFont(18), .foregroundColor: GB_INK])
        title.append(NSAttributedString(string: ":L\(level)",
            attributes: [.font: pixelFont(14), .foregroundColor: GB_INK]))
        let ts = title.size()
        title.draw(at: NSPoint(x: box.minX + 14, y: box.maxY - ts.height))

        let bandW: CGFloat = 7.5     // 세로 띠
        let lineH: CGFloat = 1.5     // 아래 선 (띠의 1/5)
        let arrowW: CGFloat = 10
        let arrowH: CGFloat = 7
        let lineY = box.minY

        // HP 유닛: 얇은 직사각형. 상대는 왼쪽 띠에서 시작해 오른쪽 끝이 살짝
        // 두꺼운 검정 마감, 나는 오른쪽 띠에 직각으로 이어진다.
        let unitH: CGFloat = 12
        let unitY = box.maxY - ts.height - unitH - 2
        let labelW: CGFloat = 28
        let unit = isPlayer
            ? NSRect(x: box.minX + 8, y: unitY, width: box.width - 8 - bandW + 1, height: unitH)
            : NSRect(x: box.minX + bandW - 1, y: unitY, width: box.width - bandW - 3, height: unitH)

        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        GB_INK.setFill(); unit.fill()
        // 트랙: 상대 쪽은 오른쪽에 4pt를 남겨 "최우측 두꺼운 검정 띠"가 되게 한다
        let trackR: CGFloat = isPlayer ? 1.5 : 4
        let track = NSRect(x: unit.minX + labelW, y: unit.minY + 1.5,
                           width: unit.width - labelW - trackR, height: unitH - 3)
        NSColor.white.setFill(); track.fill()
        if frac > 0 {
            hpColor(frac).setFill()
            NSRect(x: track.minX, y: track.minY,
                   width: track.width * frac, height: track.height).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        let hpAttr: [NSAttributedString.Key: Any] = [.font: pixelFont(Self.hpLabelSize),
                                                     .foregroundColor: HP_YELLOW]
        let hpLabel = "HP:" as NSString
        let hs = hpLabel.size(withAttributes: hpAttr)
        hpLabel.draw(at: NSPoint(x: unit.minX + 5, y: unit.minY + (unitH - hs.height) / 2),
                     withAttributes: hpAttr)

        // 숫자는 프레임(AA off)보다 먼저, 텍스트 품질을 위해 AA 켠 채로 그린다.
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
            // 오른쪽 세로 띠: 아래 선에서 게이지 위까지 (게이지와 직각으로 만난다)
            NSRect(x: box.maxX - bandW, y: lineY,
                   width: bandW, height: unit.maxY - lineY).fill()
            // 아래 선 + 왼쪽 끝의 반쪽 화살촉 (왼쪽을 향함)
            let tipX = box.minX - 6
            NSRect(x: tipX + arrowW, y: lineY,
                   width: box.maxX - (tipX + arrowW), height: lineH).fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: tipX + arrowW, y: lineY))
            arrow.line(to: NSPoint(x: tipX + arrowW, y: lineY + arrowH))
            arrow.line(to: NSPoint(x: tipX, y: lineY))
            arrow.close(); arrow.fill()
            // 경험치: 컨테이너 없이 화살촉~오른쪽 띠가 전체 범위, 우→좌로 채움
            let expX = tipX + arrowW + 2
            let exp = NSRect(x: expX, y: lineY + lineH + 2,
                             width: (box.maxX - bandW) - expX - 1, height: 4)
            EXP_BLUE.setFill()
            NSRect(x: exp.maxX - exp.width * 0.55, y: exp.minY,
                   width: exp.width * 0.55, height: exp.height).fill()
        } else {
            // 왼쪽 세로 띠
            NSRect(x: box.minX, y: lineY, width: bandW, height: unit.maxY - lineY).fill()
            // 아래 선 + 오른쪽 끝의 반쪽 화살촉 (오른쪽을 향함)
            let endX = box.maxX + 6
            NSRect(x: box.minX, y: lineY, width: (endX - arrowW) - box.minX, height: lineH).fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: endX - arrowW, y: lineY))
            arrow.line(to: NSPoint(x: endX - arrowW, y: lineY + arrowH))
            arrow.line(to: NSPoint(x: endX, y: lineY))
            arrow.close(); arrow.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()   // AA 복원 — 안 하면 이후 대화상자까지 계단이 진다
    }

    // ── 지오메트리
    var dialogBox: NSRect {
        NSRect(x: bounds.minX + pad, y: bounds.minY + pad,
               width: bounds.width - pad * 2, height: dialogH - pad * 2)
    }
    var menuBox: NSRect {
        let w = dialogBox.width * 0.56
        return NSRect(x: dialogBox.maxX - w, y: dialogBox.minY, width: w, height: dialogBox.height)
    }
    var menuInner: NSRect { menuBox.insetBy(dx: boxBorder, dy: boxBorder) }

    func itemRect(_ i: Int) -> NSRect {
        let col = CGFloat(i % 2), row = CGFloat(i / 2)
        let w = menuInner.width / 2, h = menuInner.height / 2
        return NSRect(x: menuInner.minX + col * w, y: menuInner.maxY - (row + 1) * h,
                      width: w, height: h)
    }

    // ── 하단 대화상자
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
        // 메뉴 컨테이너도 레터박스와 같은 더블라인
        let mInner = NSBezierPath(roundedRect: menuBox.insetBy(dx: 4, dy: 4), xRadius: 4, yRadius: 4)
        GB_INK.setStroke(); mInner.lineWidth = 1; mInner.stroke()

        // 캡처처럼 메뉴/메시지도 이름과 같은 큰 폰트
        let font = pixelFont(Self.bigFontSize)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: GB_INK]
        let mh = (message as NSString).size(withAttributes: attr).height
        (message as NSString).draw(at: NSPoint(x: box.minX + 16, y: box.midY - mh / 2), withAttributes: attr)

        for (i, item) in items.enumerated() {
            let cell = itemRect(i)
            let ih = (item as NSString).size(withAttributes: attr).height
            let ty = cell.midY - ih / 2
            (item as NSString).draw(at: NSPoint(x: cell.minX + 22, y: ty), withAttributes: attr)
            if i == cursor {
                ("▶" as NSString).draw(at: NSPoint(x: cell.minX + 4, y: ty), withAttributes: attr)
            }
        }
    }

    // ── 상호작용
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 126: if cursor >= 2 { cursor -= 2 }
        case 125: if cursor < 2  { cursor += 2 }
        case 123: if cursor % 2 == 1 { cursor -= 1 }
        case 124: if cursor % 2 == 0 { cursor += 1 }
        case 36, 76: activate()
        case 53: onQuit()
        default: return
        }
        needsDisplay = true
    }
    override func mouseMoved(with e: NSEvent) { hover(e) }
    override func mouseDown(with e: NSEvent) { hover(e); activate() }

    private func hover(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        for i in 0..<4 where itemRect(i).contains(p) {
            if cursor != i { cursor = i; needsDisplay = true }
        }
    }
    private func activate() {
        switch (screen, items[cursor]) {
        case (.root, "사용량 선택"): screen = .usage; cursor = 0
        case (.usage, "뒤로"):      screen = .root;  cursor = 0
        case (.root, "종료"):       onQuit()
        default: break
        }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
}

// MARK: - 패널

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// 캡처(≈2:1)에 가깝게 세로를 줄였다.
let PANEL_W: CGFloat = 460
let PANEL_H: CGFloat = 300

final class Delegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: KeyPanel?
    var monitor: Any?
    let usedPercent = 16

    func applicationDidFinishLaunching(_ n: Notification) {
        registerPixelFont()
        statusItem = NSStatusBar.system.statusItem(withLength: 130)
        if let b = statusItem.button {
            b.title = "🐾 BATTLE"
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp])
        }
        print("--- '🐾 BATTLE' 클릭 → 배틀 화면. ESC/바깥클릭 = 닫기 ---"); fflush(stdout)
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if panel != nil { closePanel(); return }
        openPanel(sender)
    }

    func openPanel(_ b: NSStatusBarButton) {
        let view = BattleView(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H),
                              usedPercent: usedPercent)
        view.onQuit = { [weak self] in self?.closePanel() }

        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = view

        var origin = NSPoint.zero
        if let win = b.window {
            let f = win.frame
            var x = f.midX - PANEL_W / 2
            var y = f.minY - PANEL_H - 4
            if let vis = (win.screen ?? NSScreen.main)?.visibleFrame {
                x = min(max(x, vis.minX + 8), vis.maxX - PANEL_W - 8)
                y = max(y, vis.minY + 8)
                y = min(y, vis.maxY - PANEL_H - 4)
            }
            origin = NSPoint(x: x, y: y)
        }

        p.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 8))
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        p.makeFirstResponder(view)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrameOrigin(origin)
            p.animator().alphaValue = 1
        }
        panel = p

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    func closePanel() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

// MARK: - 진입점

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
    registerPixelFont()
    let shots: [(Screen, Int)] = [(.root, 0), (.usage, 2)]
    let gap: CGFloat = 12
    let total = NSImage(size: NSSize(width: PANEL_W, height: PANEL_H * 2 + gap), flipped: false) { _ in
        NSColor(white: 0.25, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H * 2 + gap).fill()
        var y = PANEL_H + gap
        for (screen, cursor) in shots {
            let v = BattleView(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H), usedPercent: 16)
            v.screen = screen; v.cursor = cursor
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            rep.draw(in: NSRect(x: 0, y: y, width: PANEL_W, height: PANEL_H))
            y -= PANEL_H + gap
        }
        return true
    }
    let rep = NSBitmapImageRep(data: total.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    print("dumped: \(args[i + 1])")
    exit(0)
}

let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.accessory)
app.run()
