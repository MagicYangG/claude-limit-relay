# claude-preheat

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | **한국어**

Windows에서 Claude Code CLI로 작업하는 Claude 구독 사용자를 위한 도구이며, 하는 일은 하나입니다. 5시간 사용량 윈도우는 활성 윈도우가 없을 때 보낸 첫 메시지에 앵커됩니다 — 예약된 아주 작은 핑이 원하는 시각에 윈도우를 앵커해 두므로, 실제로 일을 시작할 때는 이미 윈도우가 돌아가고 있고 작업이 도중에 끊기는 대신 윈도우 두 개에 걸쳐 이어집니다.

## 웹 패널

로컬 주소: `localhost:7878` (영어/중국어, 헤더에서 원클릭 전환)

모듈: 실시간 쿼터 스트립(5시간 + 주간, 정확한 리셋 시각 포함 — `preheat statusline on` 을 한 번 실행하면 값이 들어옵니다) / 주간 리셋 시각 편집기(`schedule.json` 에 기록하고 바로 적용) / 일회성 예열 / 최근 7일 윈도우 활용률 라인(내부적으로 `preheat learn`)

![panel](docs/panel.png)

## 빠른 시작

**요구 사항**: Windows 10/11; [Claude Code CLI](https://code.claude.com/docs) 설치·로그인; Claude 구독; PowerShell 7 (pwsh); 관리자 권한 불필요

**추천: 아래 내용을 Claude Code(또는 다른 AI 코딩 도구)에 붙여 넣어 설치를 맡기세요:**

```text
https://github.com/MagicYangG/claude-preheat 를 클론하고 설치해 줘:
1. git clone 후 저장소 디렉터리에서 install.ps1 실행
2. 매주 윈도우가 리셋되길 원하는 시각을 나에게 물어 schedule.json에 기록
   (reset에는 목표 리셋 시각을 적는다. 예열 시각은 자동으로 reset − 5시간)
3. ./test.ps1 을 실행해 전체 케이스 통과 확인
4. preheat apply 실행 후 preheat status 출력을 보여줘
install.ps1 과 preheat apply 가 만드는 것 외에는 아무것도 등록하거나 변경하지 말 것.
```

설치가 끝나면 브라우저에서 `http://localhost:7878` 을 열어 패널로 조작하면 됩니다.

**수동 설치는 3단계**: `git clone` → `./install.ps1` → 새 터미널에서 `preheat apply`. 전체 명령은 [명령 레퍼런스](#명령-레퍼런스)를 참고하세요.

## 주의 사항

1. **Claude Code CLI 필요**: 예열은 CLI를 통해 실행되는 아주 작은 headless 프롬프트입니다
2. **이미 활성인 윈도우에 핑을 보내도 무해합니다**: 사소한 메시지 하나를 쓸 뿐 아무것도 움직이지 않습니다
3. **절전에서 깨우기**: 예약된 실행이 PC를 깨우려면 현재 전원 관리 옵션에서 절전 해제 타이머가 켜져 있어야 합니다 — 꺼져 있으면 `preheat status` 가 경고합니다

## 릴레이(relay)는 어디로 갔나요?

v0.2.0 에는 한도에 걸려 죽은 세션을 쿼터가 돌아오면 되살리는 윈도우 간 자동 재개("릴레이")가 있었습니다. Claude Code v2.1.234 가 네이티브 자동 이어가기를 추가했고 — 기본 켜짐, `/config` 의 "Continue automatically at usage limit" 에서 전환 — 자리를 지키고 있는 경우를 프로세스 안에서, 정확한 리셋 시각과 함께, 외부 감시자가 결코 따라갈 수 없는 수준으로 처리합니다. v0.3.0 은 플랫폼과 경쟁하는 대신 릴레이를 내렸습니다. 릴레이가 들어 있는 마지막 릴리스는 [v0.2.0](https://github.com/MagicYangG/claude-preheat/releases/tag/v0.2.0) 태그에 남아 있습니다. 네이티브 기능이 하지 않는 일 — 자리에 앉기 전에 윈도우를 미리 시작해 두는 것 — 이 바로 preheat 가 하는 일입니다.

## 명령 레퍼런스

평소에는 패널이면 충분합니다. 아래는 터미널·스크립트용입니다.

```powershell
preheat apply           # schedule.json 기준으로 매주 예열 작업 등록(수정 후 재실행하면 반영)
preheat status          # 로컬 활동 + 등록 작업 + 최근 로그
preheat reset 20:00     # 일회성: 윈도우를 20:00에 리셋(15:00 자동 예열)
preheat at 15:00        # 일회성: 15:00에 예열
preheat +2h             # 일회성: 2시간 후 예열
preheat learn           # 최근 30일 리듬으로 예열 시각 제안 + 윈도우 활용률 리포트(learn auto = 기록+적용)
preheat statusline on   # statusline 투명 탭으로 정확한 리셋 시각을 패널 쿼터 스트립에 공급(순수 패스스루; off = 복원)
preheat off             # 예열 작업 전체 제거
claude-panel            # 로컬 웹 패널 열기
```

`schedule.json` 의 `reset` 은 **목표 리셋 시각**이며, 예열 시각은 자동으로 reset − 5h. `proxy` 를 비우면 프록시를 쓰지 않습니다.

## 제거

```powershell
preheat off             # 예열 작업 전체 제거
preheat statusline off  # 원래 statusline 복원(투명 탭을 켰던 경우)
```

그 후 PowerShell 프로필(`$PROFILE.CurrentUserAllHosts`)에서 `# >>> claude-preheat functions >>>` 부터
`# <<< claude-preheat functions <<<` 사이의 줄을 지우고(예전 버전으로 설치했다면
`claude-limit-relay` 마커일 수 있습니다), 저장소 디렉터리를 삭제하면 됩니다.
