# Claude Monster

macOS 메뉴바에서 **Claude 사용 한도**를 포켓몬 HP바 스타일로 보여주는 개인용 위젯.

- 세션(5시간) / 주간(7일) / 주간 Fable 한도 중 원하는 걸 추적 (기본값: 세션, 위젯 클릭으로 전환)
- 남은 %에 따라 표정이 바뀌는 도트 클로드 캐릭터 (건강 → 지침 → 아픔 → 기절)
- **클로드를 클릭하면 쓰다듬을 수 있음** — 싱긋 웃으며 애정 대사로 반응
- "포켓몬센터까지 남은 시간"(=한도 리셋 시각) ↔ 상태 대사가 부드럽게 번갈아 표시
- IDE extension과 **같은 데이터 소스**(`/api/oauth/usage`)라 값이 정확함
- 앱 내 자동 업데이트 + 로그인 시 자동 시작 (둘 다 메뉴에서 켜고 끔)
- 외부 의존성 없음 (Swift 표준 라이브러리 + 번들 픽셀 폰트만 사용)

---

## 1. 설치

**요구 사항**: macOS 13+, 그리고 이 맥에서 **Claude Code에 로그인**돼 있을 것
(CLI가 Keychain에 저장한 OAuth 토큰을 그대로 읽어서 씁니다).

### 방법 A — 앱 다운로드 (터미널 불필요, 권장)

1. [Releases](https://github.com/wodus1201/ClaudeMonster/releases/latest)에서 `ClaudeMonster.zip` 다운로드
2. 압축을 풀고 `ClaudeMonster.app`을 **응용 프로그램** 폴더로 드래그
3. 더블클릭해서 실행 → 메뉴바 오른쪽에 클로드 HP 위젯이 뜹니다

**첫 실행 시 "확인되지 않은 개발자" 경고가 뜹니다.** 이 앱은 Apple 유료 개발자
인증서로 서명되어 있지 않기 때문입니다. 한 번만 이렇게 열어주세요:

> `ClaudeMonster.app`을 **우클릭 → 열기** → 대화상자에서 다시 **열기**
>
> (또는 시스템 설정 → 개인정보 보호 및 보안 → 아래쪽 "확인 없이 열기")

이후에는 그냥 더블클릭으로 열립니다.

그 다음은 앱이 안내합니다. 첫 실행 때 환영 창이 떠서 필요한 것(Claude Code
로그인)을 알려주고, 거기서 바로 **"로그인 시 자동 시작"**을 켤 수 있습니다.

**"Keychain 접근을 허용하시겠습니까"** 팝업에는 **"항상 허용"**을 누르세요.
(Claude Code 로그인 토큰을 읽기 위함이며, 토큰을 외부로 전송하지 않습니다 —
아래 "동작 원리" 참고.)

아직 Claude Code에 로그인하지 않았다면 위젯 메뉴에 "로그인이 필요합니다"가
뜨고, **"로그인하는 방법 보기…"**에서 단계를 확인할 수 있습니다.

### 방법 B — 소스에서 빌드 (개발자용)

Xcode Command Line Tools(`swiftc`)가 추가로 필요합니다.

```bash
git clone https://github.com/wodus1201/ClaudeMonster.git
cd ClaudeMonster
./install.sh
```

`swiftc` 확인 → 이 맥에 맞게 빌드 → `/Applications`에 심볼릭 링크 → 실행까지 합니다.
자동 시작은 등록하지 않으니 위젯 메뉴의 **"로그인 시 자동 시작"** 토글을 쓰세요.

---

## 2. 업데이트

**앱을 다운로드해서 쓰는 경우**, 업데이트는 앱이 스스로 처리합니다.
6시간마다 GitHub Releases를 확인하고, 새 버전이 있으면 메뉴에
**"🎁 새 버전 x.y 설치"**가 나타납니다. 누르면 다운로드 → 교체 → 재시작까지
자동입니다. 직접 확인하려면 메뉴의 **"업데이트 확인"**을 누르세요.

**소스에서 빌드한 경우**는 인앱 업데이트가 동작하지 않습니다 (빌드 산출물을
릴리즈 zip으로 덮어쓰면 곤란하니 앱이 거부합니다). 대신:

```bash
cd ~/ClaudeMonster && ./update.sh    # git pull → 재빌드 → 재시작
```

---

## 3. 일상적으로 쓰는 명령어

| 하고 싶은 것 | 방법 |
|---|---|
| 지금 당장 새로고침 | 메뉴바 위젯 클릭 → "지금 새로고침" |
| 추적할 한도 바꾸기 (세션/주간/Fable) | 메뉴바 위젯 클릭 → 원하는 항목 클릭 (✓ 표시로 확인, 재시작해도 유지됨) |
| 간결/상세 모드 전환 (메뉴바 폭) | 메뉴바 위젯 클릭 → "간결 모드" 체크 토글 (재시작해도 유지됨) |
| 로그인 시 자동 시작 켜기/끄기 | 메뉴바 위젯 클릭 → "로그인 시 자동 시작" 토글 |
| **클로드 쓰다듬기** | 메뉴바 위젯의 **도트 클로드를 클릭** (표정이 바뀌고 애정 대사가 3초간 뜹니다) |
| 앱이 도는지 확인 | `pgrep -x ClaudeMonster` |
| 소스에서 코드 수정 후 반영 | `./build.sh && ./start.sh` |
| 완전히 제거 | `cd ~/ClaudeMonster && ./uninstall.sh` |

> 앱이 켜져 있는 상태에서 `build.sh`가 `Operation not permitted`로 실패하면,
> 실행 중인 인스턴스가 바이너리를 잡고 있는 것입니다. `./stop.sh` 후 다시 빌드하세요.

---

## 4. 목 모드 (Mock Mode) — 네트워크 요청 없이 UI만 테스트

디자인/애니메이션/레이아웃을 다듬을 때마다 실제 API를 부르면 짧은 시간에 호출이 몰려 **HTTP 429(요청 과다)**로 막힐 수 있습니다. 목 모드는 **가짜 데이터를 실제와 동일한 렌더링 경로로 흘려보내면서 네트워크 호출을 한 번도 하지 않습니다.**

```bash
cd ~/ClaudeMonster && ./build.sh
CLAUDEMONSTER_MOCK=1 ./build/ClaudeMonster.app/Contents/MacOS/ClaudeMonster
```

- 메뉴바에 **진짜와 동일하게** 위젯이 뜨고 애니메이션(bob·깜빡임)·크로스페이드·클릭으로 한도 전환까지 **전부 실제처럼 동작**합니다.
- "지금 새로고침"을 눌러도 네트워크 대신 같은 가짜 데이터를 다시 그립니다.
- `fetchUsage()`(진짜 API 호출)는 이 모드에서 **절대 호출되지 않습니다** — 429 걱정 없이 얼마든지 재실행해도 됩니다.

**세션 사용률을 바꿔가며 표정/색을 보고 싶을 때**:

```bash
CLAUDEMONSTER_MOCK=1 CLAUDEMONSTER_MOCK_PERCENT=85 ./build/ClaudeMonster.app/Contents/MacOS/ClaudeMonster
```

`85` 대신 0~100 사이 숫자를 넣으면 그 사용률(그 표정·색)로 바로 뜹니다.

| 사용률 (`CLAUDEMONSTER_MOCK_PERCENT`) | 표정 |
|---|---|
| 0~50 | 건강 (초록) |
| 51~80 | 지침 (주황) |
| 81~99 | 아픔 (빨강) |
| 100 | 기절 (회색조, X눈) |

**주의**: 목 모드는 터미널에서 직접 실행하는 임시 테스트용입니다. 터미널을 닫거나 `pkill -x ClaudeMonster`하면 꺼집니다. 테스트가 끝나면 실제 앱을 다시 켜세요:

```bash
./start.sh
```

**정적 이미지로만 빠르게 훑어보고 싶을 때** (여러 상태를 한 PNG에 쌓아서 보여줌, 창을 띄우지 않고 파일로 저장):

```bash
CLAUDEMONSTER_DUMP=/tmp/preview.png ./build/ClaudeMonster.app/Contents/MacOS/ClaudeMonster
open /tmp/preview.png
```

---

## 5. 제거

**앱을 다운로드해서 쓰는 경우**: 지우기 **전에** 위젯 메뉴에서
"로그인 시 자동 시작"을 꺼주세요. 그 다음 메뉴에서 "종료"하고
`/Applications/ClaudeMonster.app`을 휴지통으로 옮기면 됩니다.

(먼저 지워버렸다면 시스템 설정 → 일반 → 로그인 항목에서 ClaudeMonster를
직접 빼주세요. 앱이 없으면 코드로 등록을 해제할 수 없습니다.)

**소스에서 빌드한 경우**:

```bash
cd ~/ClaudeMonster && ./uninstall.sh
```

앱을 종료하고 `/Applications` 항목과 구식 LaunchAgent를 정리합니다.
소스 폴더 자체는 안 지워지니, 완전히 없애려면 폴더도 수동 삭제하세요.

---

## 6. 새 버전 배포하기 (메인테이너용)

1. `VERSION` 파일의 숫자를 올립니다 (예: `1.1` → `1.2`)
2. 변경사항을 전부 커밋합니다
3. `./release.sh`

universal 바이너리(arm64 + x86_64)로 빌드해 `ClaudeMonster.zip`을 만들고,
`v<VERSION>` 태그를 밀어 GitHub Release로 올립니다. 기존 사용자의 앱은
6시간 안에 이 릴리즈를 발견하고 메뉴에 설치 항목을 띄웁니다.

> 태그와 `VERSION`은 반드시 일치해야 합니다 (`v1.2` ↔ `1.2`). 앱이 이 둘을
> 비교해 새 버전 여부를 판단하기 때문이며, `release.sh`가 어긋나면 중단합니다.

### 앱 아이콘 바꾸기

아이콘은 위젯에 그려지는 것과 **똑같은 픽셀 스프라이트**에서 생성됩니다.
`clawdBase`나 `spriteGrids`를 수정했다면:

```bash
./build.sh && ./make-icon.sh    # icon.icns 재생성
```

`build.sh`가 `icon.icns`를 번들에 자동으로 넣습니다. 생성된 파일은 커밋하세요
(없어도 빌드는 되지만 macOS 기본 아이콘이 표시됩니다).

---

## 7. 설정 조절 (`src/main.swift` 상단 근처)

| 상수 | 위치 | 의미 | 참고 |
|---|---|---|---|
| `REFRESH_SECONDS` | 파일 상단 | 사용량 조회 주기(초) | **너무 짧으면 HTTP 429**가 날 수 있음. 240초(4분) 이상 권장 |
| `MAX_BACKOFF` | 파일 상단 | 429 발생 시 최대 백오프(초) | 기본 1800(30분) |
| `TIME_HOLD` / `FLAVOR_HOLD` | AppDelegate 안 | 리셋 시간 ↔ 대사 각각 표시 시간(초) | |
| `CROSSFADE` | AppDelegate 안 | 스왑 전환 시간(초) | |
| `spriteNameGap` / `gap` / `flavorGap` | `buildImage` 안 | 위젯 내부 요소 간격(pt) | |

수정 후엔 "3. 일상적으로 쓰는 명령어"의 재빌드 명령으로 반영.

---

## 8. 동작 원리

- `GET https://api.anthropic.com/api/oauth/usage`
  - 헤더: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`
  - 토큰: macOS Keychain 항목 `Claude Code-credentials` (없으면 `~/.claude/.credentials.json`으로 폴백) — Claude Code CLI가 로그인할 때 이미 저장해 둔 바로 그 토큰을 읽기만 함
- 응답의 `limits[]`에서 세션/주간/Fable 한도의 `percent`, `resets_at`를 읽어 표시
- 기본 추적 대상은 **세션(5시간)**. 위젯 클릭 시 다른 한도로 전환 가능하며 선택은 `UserDefaults`에 저장돼 재시작 후에도 유지됨
- 429가 오면 지수 백오프로 자동 대기 후 복구하며, 대기 중엔 위젯이 회색 게이지 + "졸고 있다" 대사로 바뀜 (데이터 유무와 무관하게 항상 위젯 UI로 표시, 텍스트 폴백 없음)
