# ClaudeMonster

macOS 메뉴바에서 Claude 사용 한도를 포켓몬 HP바로 보여주는 개인용 위젯.
Swift 단일 파일(`src/main.swift`) + 셸 스크립트. 외부 의존성 없음.

사용법·설치·목 모드 실행법은 [README.md](README.md)에 있다. 이 문서는 코드를
읽어도 드러나지 않는 제약과, 밟기 쉬운 함정만 적는다.

## 빌드 / 실행

```bash
./build.sh                 # 컴파일 → build/ClaudeMonster.app (단일 아키텍처, 빠름)
./stop.sh && ./start.sh    # 재시작
UNIVERSAL=1 ./build.sh     # arm64 + x86_64 (배포용, 느림)
```

앱이 실행 중이면 `build.sh`가 `Operation not permitted`로 실패한다. 실행 중인
인스턴스가 바이너리를 잡고 있는 것이므로 `./stop.sh` 후 다시 빌드한다.

UI를 만질 때는 **반드시 목 모드**를 쓴다. 실제 API를 반복 호출하면 HTTP 429로
막히고, 그러면 위젯이 최대 30분 백오프에 들어간다.

```bash
CLAUDEMONSTER_MOCK=1 ./build/ClaudeMonster.app/Contents/MacOS/ClaudeMonster
CLAUDEMONSTER_MOCK=1 CLAUDEMONSTER_MOCK_PERCENT=85 ./build/...   # 표정/색 확인
CLAUDEMONSTER_DUMP=/tmp/preview.png ./build/...                  # 창 없이 PNG로
```

목 모드는 `fetchUsage()`를 절대 호출하지 않는다(`apply()`가 `isMocking`이면
`scheduleNext()`를 건너뜀). 이 성질을 깨뜨리지 말 것 — 목 모드의 존재 이유다.

## 아키텍처에서 알아야 할 것

**메뉴바 위젯은 텍스트가 아니라 통째로 그린 `NSImage`다.** `buildImage()`가 매
프레임 픽셀을 그린다. 애니메이션 타이머는 12fps로 돌지만 `lastSignature`가
같으면 그리지 않고 빠져나가므로 idle CPU가 0에 가깝다. 화면에 보이는 상태를
새로 추가하면 **그 상태를 `lastSignature`에 포함시켜야** 한다. 빠뜨리면 값이
바뀌어도 다시 그려지지 않는다.

**대사 슬롯의 폭은 `allSlotStrings()`의 최댓값으로 고정된다.** 슬롯에 새 문자열을
띄우게 되면 그 문자열을 `allSlotStrings()`에도 추가해야 한다. 안 하면 그 문구가
뜨는 순간 위젯 전체가 출렁인다.

**스프라이트는 `clawdBase` 하나에서 파생된다.** 표정은 눈 두 줄(인덱스 5, 6)만
갈아끼운 것이고, 앱 아이콘도 같은 그리드에서 렌더된다(`writeIconPNG`). 그리드를
고쳤다면 `./build.sh && ./make-icon.sh`로 `icon.icns`를 재생성해 커밋한다.

**상태 아이템에 `statusItem.menu`를 붙이지 않는다.** 클릭을 `buttonClicked()`가
직접 라우팅한다 — 스프라이트 히트박스(`spriteHitMaxX`, 그릴 때 기록됨) 안이면
쓰다듬기, 밖이면 메뉴를 임시로 붙였다 떼서 띄운다.

## 지뢰

**`LEGACY_*` 상수는 이름을 바꾸면 안 된다.** (`main.swift`, `lib.sh`) 1.2 이전
이름인 "ClaudeBattery"를 가리키는 **역사적 값**이다. 옛 설치가 남긴 LaunchAgent와
프로세스를 정리하는 데 쓰이므로, 리네임하면 정리 코드가 조용히 동작을 멈춘다.

**`VERSION`과 릴리즈 태그는 반드시 일치해야 한다** (`1.3` ↔ `v1.3`). 앱이 이 둘을
비교해 새 버전 여부를 판단한다. `release.sh`가 어긋나면 중단시킨다.

**소스 빌드에서는 인앱 업데이트가 동작하지 않는다.** 번들의 부모 디렉터리가
`build/`면 업데이터가 `.devBuild` 에러로 거부한다. 업데이트 흐름을 실제로
검증하려면 릴리즈 zip을 진짜 `/Applications`에 풀어야 한다.

**`REFRESH_SECONDS`를 줄이지 말 것.** 240초(4분) 미만이면 429를 부른다.

## 릴리즈

```bash
# 1) 코드 수정 + 커밋 (스프라이트를 고쳤다면 icon.icns도 함께)
# 2) VERSION을 올리고 커밋
git push          # release.sh는 태그만 밀고 브랜치는 밀지 않는다
./release.sh      # universal 빌드 → zip → v<VERSION> 태그 → GitHub Release
```

릴리즈에 `.zip` 에셋이 없으면 앱의 업데이터가 조용히 무시한다
(`fetchLatestRelease()`가 실패를 삼켜 위젯을 방해하지 않도록 설계됨).
`gh release view v<VERSION>`으로 에셋이 붙었는지 확인할 것.

## 배틀 화면

위젯 좌클릭 시 내려오는 커스텀 패널. 우클릭은 기존 `NSMenu`를 띄운다 —
패널이 깨져도 앱을 끌 수단이 남아야 하기 때문이다.

```bash
CLAUDEMONSTER_BATTLE=/tmp/b.png ./build/ClaudeMonster.app/Contents/MacOS/ClaudeMonster
```

창 없이 세 페이지를 한 PNG로 뽑는다. 스프라이트 그리드를 고쳤다면 행 수와 폭이
균일한지 반드시 확인할 것 — 어긋나도 컴파일은 통과하고 렌더만 조용히 깨진다.

메뉴 셀은 폭 여유가 1~2pt뿐이다. 항목 이름을 바꾸거나 패딩을 늘리기 전에
[docs/battle-ui.md](docs/battle-ui.md)의 "레이아웃의 함정"을 읽을 것.
