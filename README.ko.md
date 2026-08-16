# claude-limit-relay

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | **한국어**

Claude Code CLI를 사용하는 Claude 구독 사용자를 위한 도구입니다. 두 가지를 합니다:

- **사용량 윈도우 예열** — Windows 작업 스케줄러로 지정한 시각에 윈도우를 선점합니다(5시간 윈도우는 윈도우가 비어 있을 때 보낸 첫 메시지에 앵커됩니다). 본격적으로 일을 시작할 때 5시간 윈도우 두 개에 걸쳐 쓸 수 있습니다
- **윈도우 간 작업 릴레이** — 작업이 5시간 한도에 걸리기 직전이거나 이미 걸렸을 때, 패널에 등록한 작업이 자동으로 대기하다가 한도가 풀리는 즉시 이어서 실행합니다. 돌아오면 클릭 한 번으로 이어받습니다

## 웹 패널

로컬 주소: `localhost:7878` (영어/중국어, 헤더에서 원클릭 전환)

세 모듈: 사용량 윈도우 예열 / 릴레이 큐 / 인수

![panel](docs/panel.png)

## 빠른 시작

**요구 사항**: Windows 10/11; [Claude Code CLI](https://code.claude.com/docs) 설치·로그인; Claude 구독; PowerShell 7 (pwsh); 관리자 권한 불필요

**추천: 아래 내용을 Claude Code(또는 다른 AI 코딩 도구)에 붙여 넣어 설치를 맡기세요:**

```text
https://github.com/MagicYangG/claude-limit-relay 를 클론하고 설치해 줘:
1. git clone 후 저장소 디렉터리에서 install.ps1 실행
2. 매주 윈도우가 리셋되길 원하는 시각을 나에게 물어 schedule.json에 기록
   (reset에는 목표 리셋 시각을 적는다. 예열 시각은 자동으로 reset − 5시간)
3. ./test.ps1 을 실행해 전체 케이스 통과 확인
4. preheat apply 실행 후 preheat status 출력을 보여줘
install.ps1 과 preheat apply 가 만드는 것 외에는 아무것도 등록하거나 변경하지 말 것.
```

설치가 끝나면 브라우저에서 `http://localhost:7878` 을 열어 패널로 조작하면 됩니다.

**수동 설치는 3단계**: `git clone` → `./install.ps1` → 새 터미널에서 `preheat apply`. 전체 명령은 문서 끝의 [명령 레퍼런스](#명령-레퍼런스)를 참고하세요.

## 주의 사항

1. **Claude Code CLI 필요**: 예열과 릴레이 모두 Claude Code CLI를 통해 실행됩니다
2. **재개 윈도우**: 재개는 같은 디렉터리·같은 대화·같은 모델과 effort로, 다른 터미널 윈도우에서 실행됩니다. 인수한 뒤에는 원래 윈도우를 닫아 두 윈도우가 같은 대화에 동시에 쓰지 않게 하세요. 재개는 `--dangerously-skip-permissions` 로 실행됩니다(무인 상태에서는 도구 호출을 승인할 수 없기 때문). 보안 함의는 [SECURITY.md](SECURITY.md)를 참고하세요.
3. **모델별 주간 한도 폴백**: Claude 구독에는 모델별 주간 한도가 있습니다. 작업 등록 시 한도에 걸리면 opus로 바꿔 끝까지 실행할지, 멈춰서 기다릴지 선택할 수 있습니다

## 명령 레퍼런스

평소에는 패널이면 충분합니다. 터미널·스크립트용:

### 예열(preheat)

```powershell
preheat apply         # schedule.json 기준으로 매주 예열 작업 등록(수정 후 재실행하면 반영)
preheat status        # 로컬 활동 + 등록 작업 + 최근 로그
preheat reset 20:00   # 일회성: 윈도우를 20:00에 리셋(15:00 자동 예열)
preheat at 15:00      # 일회성: 15:00에 예열
preheat +2h           # 일회성: 2시간 후 예열
preheat learn         # 최근 30일 리듬으로 예열 시각 제안 + 윈도우 활용률 리포트(learn auto = 기록+적용)
preheat off           # 예열 작업 전체 제거
```

`schedule.json` 의 `reset` 은 **목표 리셋 시각**이며, 예열 시각은 자동으로 reset − 5h. `proxy` 를 비우면 프록시를 쓰지 않습니다.

### 릴레이(relay)

**두 명령**: 떠나기 전 `relay arm -Watch`, 돌아와서 `relay takeover`.

relay는 순수 PowerShell이며 어떤 Claude 프로세스에도 의존하지 않습니다. 재개는 `claude --resume <원래 세션> -p "<계속 프롬프트>"` 를 실행합니다 — 대화 전체 히스토리를 마운트하고 실제 프롬프트로 무엇을 이어갈지 알려줍니다.

| 시나리오 | 명령 |
|---|---|
| 이미 한도에 걸림, 자리에 있음 | `relay arm` (후보 세션 확인; `-Yes` 로 생략) |
| 곧 걸릴 것 같음 | `relay arm -Watch` (보초: 프로브 0회, 트랜스크립트만으로 판정) |
| 돌아와서 인수 | `relay takeover` (세션 버킷에 맞는 디렉터리로 이동 + 원래 대화 마운트 + 대화형 CLI 실행, 승인 생략 유지. 원래 윈도우는 닫을 것) |

```powershell
relay arm -Prompt "테스트 끝내고 마무리해"   # 계속 프롬프트 지정
relay status                                # 큐 상태 / 프로브 작업 / 최근 로그
relay legs a3f8 5                           # 등록 유지한 채 릴레이 상한을 5로 변경
relay disarm                                # 등록 해제(진행 중인 재개 프로세스 종료)
relay doctor                                # 사전 조건 점검: CLI / 작업 / 절전 해제 플래그 / 패널
relay test                                  # 샌드박스 전체 체인 리허설(mock claude, 쿼터 소모 없음)
relay statusline on                         # statusline 투명 탭으로 정확한 리셋 시각 확보(off = 복원)
```

작업이 걸칠 수 있는 윈도우 수: 직접 쓴 1개 + 기본 3개 = 최대 4개(약 20시간). `-MaxLegs N` 으로 조절할 수 있습니다(등록 후에도 `relay legs` 나 패널에서 변경 가능). 주간 한도에 주의하세요.

### 제거

```powershell
preheat off      # 예열 작업 전체 제거
relay disarm     # 등록 작업 전체 취소
```

그 후 `$PROFILE` 에서 `# >>> claude-limit-relay functions >>>` 부터
`# <<< claude-limit-relay functions <<<` 사이의 줄을 지우고, 저장소
디렉터리를 삭제하면 됩니다.
