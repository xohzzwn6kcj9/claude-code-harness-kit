# claude-code-harness-kit

[Claude Code](https://code.claude.com) 훅 모음과 읽기 전용 repo 분석 스킬 하나로 이루어진 작은
키트입니다. 핵심 지향점은 **프롬프트 마찰은 줄이되 안전성은 그대로**입니다 — 명백히 읽기 전용인
동작은 자동 승인하고, 시크릿을 흘리거나 상태를 망가뜨리는 동작은 강제 차단하며, 그 외에는 끼어들지
않습니다.

모든 구성 요소는 선택적(opt-in)이고 골라 쓸 수 있습니다 — 원하는 것만 설치하고 나머지는 건너뛰세요.

## 구성 요소

| 구성 요소 | 종류 | 역할 |
|-----------|------|------|
| [`hooks/auto-approve-readonly.sh`](hooks/auto-approve-readonly.sh) | PreToolUse | 읽기 전용 도구 + 읽기 전용 MCP 도구 + **모든** 세그먼트가 읽기 전용인 Bash 명령줄을 승인합니다. 나머지는 모두 일반 흐름에 위임합니다. **절대 차단하지 않습니다.** |
| [`hooks/deny-secret-file-reads.sh`](hooks/deny-secret-file-reads.sh) | PreToolUse | `.env`/credential/key 파일의 파일 전체 읽기(Bash + Read)를 강제 차단하고 `grep KEY file` 방식으로 유도합니다. |
| [`hooks/secret-scan.sh`](hooks/secret-scan.sh) | git pre-push | push되는 커밋 범위를 대상으로 한 결정론적 시크릿 스캔(gitleaks가 있으면 사용, 없으면 엄선된 정규식). 수동 `git push`에서도 동작합니다. |
| [`hooks/playwright-screenshot-guard.sh`](hooks/playwright-screenshot-guard.sh) | PreToolUse | Playwright MCP 스크린샷이 repo 루트에 떨어지지 않게 막습니다(상대 경로 파일명은 추적되지 않는 PNG를 흘립니다). |
| [`hooks/bash-guards/`](hooks/bash-guards) | PreToolUse | **취향이 반영된** 편의용 가드(아래 참고). 각각 독립적이라 원하는 것만 설치하세요. |
| [`skills/repo-radar/`](skills/repo-radar) | skill | 읽기 전용 git/branch/merge/PR/검색 분석을 Python(셸 미사용)으로 수행해 zsh 단어 분리, glob 함정, 체인 명령 프롬프트를 회피합니다. |

이 키트 전반을 관통하는 두 가지 설계 원칙:

1. **애매하면 위임한다(defer).** false negative의 비용은 권한 프롬프트 한 번이지만, false positive는
   부작용이 있는 무언가를 조용히 실행시킵니다. Bash 분석은 의도적으로 보수적입니다.
2. **훅의 `allow`는 settings의 `deny` 규칙을 절대 무시하지 못한다.** Claude Code에서 deny 규칙은
   PreToolUse 훅이 무엇을 반환하든 관계없이 평가되며, exit 2로 종료하는 훅은 호출을 차단합니다.
   실제 최후의 방어선으로 `permissions.deny` 기준선(`settings.example.json` 참고)을 유지하세요.

## 빠른 시작

```
git clone https://github.com/xohzzwn6kcj9/claude-code-harness-kit.git
cd claude-code-harness-kit
bash tests/run.sh && bash tests/guards.test.sh   # 선택적 셀프 테스트, "fail: 0" 기대

./install.sh            # 코어 훅만
./install.sh --all      # 코어 훅 + bash-guards + repo-radar 스킬
./install.sh --guards   # 코어 + 취향 반영 bash-guards
./install.sh --radar    # 코어 + repo-radar 스킬
```

그다음 훅 연결(wiring) 설정을 `~/.claude/settings.json`에 병합하세요 — 전체 예시는
[`settings.example.json`](settings.example.json)을 참고하세요. 세션을 재시작하거나(또는 `/hooks`
실행) `git status`를 실행해 보면 프롬프트가 뜨지 않습니다.

**요구 사항**: 읽기 전용 훅에는 `jq`와 `perl`, 스크린샷/grep/brace 가드에는 `python3`, 시크릿
스캐너에는 `git`(선택적으로 `gitleaks`)이 필요합니다. 기본 macOS에는 모두 들어 있고 대부분의 Linux
배포판도 마찬가지입니다. 훅은 **fail open**입니다 — 의존성이 없으면 아무것도 승인하지도 차단하지도
않으므로 평소대로 프롬프트만 뜹니다. 최신 Claude Code 버전을 사용하세요(훅이 현재
`hookSpecificOutput.permissionDecision` 형식을 출력합니다).

---

## 코어 훅

### auto-approve-readonly.sh

도구 호출이 명백히 읽기 전용일 때만 승인하고, 그렇지 않으면 아무것도 출력하지 않은 채 일반 권한
흐름(여러분의 allow/deny 규칙, 그다음 프롬프트)이 결정하도록 둡니다.

**직접 승인되는 도구:** `Read`(시크릿처럼 보이는 파일은 제외 — 위임됨), `Glob`, `Grep`,
`NotebookRead`, `WebFetch`, `WebSearch`. MCP 도구는 끝부분 도구명으로 매칭되므로
`mcp__<server>__*`와 플러그인 형식 `mcp__plugin_<plugin>_<server>__*`가 모두 동작합니다 —
Playwright **관찰(observation)** 도구(`browser_snapshot`, `browser_console_messages`,
`browser_navigate`, …; click/type/evaluate 같은 상호작용 도구는 의도적으로 계속 프롬프트가 뜸)와
Serena 코드 내비게이션 도구가 해당됩니다.

> `WebFetch`/`WebSearch`/`browser_navigate`는 *로컬에서는* 읽기 전용이지만 외부 서버로 요청(그리고
> 그 URL)을 보냅니다. 그 점이 위협 모델상 중요하다면 훅에서 해당 줄을 제거하세요.

**Bash:** 명령줄은 그 안의 **모든** 명령 — 파이프 세그먼트, `&&`/`||`/`;`/`&` 멤버, 루프 본문,
`v=$(...)` 치환 본문 — 이 읽기 전용 목록에 있고 **동시에** 명령별 플래그 검증을 통과할 때만
승인됩니다:

```
cat ls fd find grep rg head tail wc tree pwd echo which file stat du df uname sw_vers whoami id
groups date env printenv ps sort uniq nl tac rev strings cmp diff comm tr cut column fold jq yq
realpath readlink dirname basename hostname uptime printf type test true false less more od
hexdump cksum shasum sha256sum md5 md5sum locale getconf cd git gh gradlew docker kubectl
```

안전한 *이름*이 안전한 *명령*을 뜻하지는 않으므로, 다음 명령들은 추가로 플래그 검증을 거칩니다:

| 명령 | 승인 | 거부(위임) |
|---------|----------|--------------------|
| `git` | `status log diff show blame rev-parse ls-files ls-tree ls-remote cat-file merge-base rev-list shortlog grep reflog[ show] …`; `branch`/`tag`/`remote`는 플래그만 있을 때; `stash list`, `worktree list`, `config --get/--list` | `push commit checkout rebase merge fetch reset`, `branch <name>`, `tag <name>`, `remote add`, `reflog expire`, `stash pop`, `config <set>` |
| `gh` | `pr/issue/run/repo/release/workflow/gist/label/cache/ruleset` × `list/view/status/diff/checks`; `auth status`, `status`, `search …` | `pr merge`, `repo delete`, `pr create`, **`api`**(POST 가능), 그 외 전부 |
| `find` | 검사/출력 술어(test/print); `-exec`/`-execdir`는 읽기 전용 허용 목록 대상으로만 | `-delete`, `-fprintf`/`-fprint`/`-fls`, `-ok`, `-exec rm/sh/…` |
| `sort` | 일반 정렬 | `-o`/`--output` |
| `uniq` | 플래그만(stdin) | 파일 피연산자(2번째 피연산자 = 출력 파일) |
| `env` | 인자 없음 / 플래그 / `VAR=val` 만 | `env <command>`(실행함 — 전형적 우회) |
| `date` | 포매팅 | `-s`/`--set` |
| `tree` | 목록 출력 | `-o` |
| `docker` | `ps images inspect logs version info stats top port diff context ls/inspect` | `run rm exec build push …` |
| `kubectl` | `get describe logs explain version top api-resources diff` | `apply delete edit scale …` |
| `gradlew` | `tasks projects properties dependencies help --version` | `build test publish …` |

이름을 따지기 전에 먼저 강제되는 구조적 규칙:

- **리다이렉트**: `2>&1`, `>&2`, `>/dev/null`, `2>/dev/null`은 괜찮고, 그 외 `>`/`>>`는 위임됩니다.
  `< file` 입력은 괜찮습니다(구분자에서 멈추므로 `< f;rm x`로 명령을 밀반입할 수 없음).
- **명령 치환**: `v=$(...)` 형태만 승인 가능하며 그 본문은 세그먼트로 검증됩니다. 그 외 위치의
  `$(…)`(명령 이름 자리, 또는 `sort $(echo -o evil)`처럼 플래그를 밀반입)는 위임됩니다.
  큰따옴표 안의 `"$(…)"`도 위임됩니다. **백틱**은 어디에 있든 위임됩니다.
- **Heredoc**(`<<`)과 **프로세스 치환**(`<(`/`>(`)은 위임됩니다.
- `&`(백그라운드)와 줄바꿈은 구분자입니다. 셸 키워드는 벗겨내므로 루프 본문의 `do rm $f`도 여전히
  `rm`으로 인식됩니다. 따옴표로 묶인 문자열은 비활성 데이터로 취급됩니다.

**기본 목록에 의도적으로 *넣지 않은* 것들:** `sed`/`awk`/`perl`/`python3`/`node`(따옴표 안의 프로그램
텍스트가 파일을 쓰거나 `system()`을 호출할 수 있음), `curl`/`wget`(POST, `-o`),
`tee`/`xargs`/`eval`/`exec`/`sudo`, `xxd`/`base64`(`-o`/2번째 인자로 쓰기). 파일을 편집하지 않고
환경 변수로 목록을 확장할 수 있습니다:

```jsonc
// settings.json 훅 항목에서:
"command": "AAR_SAFE_CMDS=\"$AAR_SAFE_CMDS pytest\" ~/.claude/hooks/auto-approve-readonly.sh"
```

(`AAR_SAFE_CMDS`, `AAR_FIND_EXEC_SAFE`, `AAR_GIT_SUBCMDS` — 공백 구분. 가장 간단한 방법은 스크립트
상단의 기본값을 직접 편집하는 것입니다.)

### deny-secret-file-reads.sh

폭넓은 읽기 승인과 짝을 이룹니다: `cat`이 자동 승인되고 나면 `cat .env`가 그대로 통과하고, 트랜스크립트에
찍힌 시크릿은 영구히 남습니다. 이 훅은 `.env`, `*credential*`, `*secret*`, `*.pem`, `*.key`,
`id_rsa*`, `.netrc`, `.npmrc`, `.pgpass`, 키스토어 등에 매칭되는 경로의 파일 전체 덤프
(`cat`/`head`/`tail`/`less`/`bat`/`strings`/`od`/`xxd`/`base64`/… 또는 `Read` 도구)를 강제
차단합니다(exit 2 + 교정 힌트). `.env.example`/`.sample`/`.template`은 예외입니다. 표적 읽기
(`grep API_KEY .env`)는 계속 허용되므로 모델이 한 단계 만에 스스로 교정합니다.

### secret-scan.sh (git pre-push)

push되는 범위의 **추가된 줄**을 스캔해 적중 시 push를 차단하는 결정론적 백스톱입니다. 설치되어 있으면
`gitleaks`를 사용하고(권위 있는 도구), 없으면 자체 포함된 엄선 정규식 + 민감 파일명 검사를 명백한
플레이스홀더(`EXAMPLE`, `dummy`, `<...>`, …) 허용 목록과 함께 사용합니다. Claude 세션 밖의 수동
`git push`를 포함해 모든 push에서 동작합니다. repo별로 연결하세요:

```
cp hooks/githooks/pre-push <repo>/.git/hooks/pre-push && chmod +x <repo>/.git/hooks/pre-push
# 또는 추적되는 hooks 디렉터리를 쓰려면:
git config core.hooksPath hooks/githooks
```

스크립트 상단의 `rules` 배열에 여러분만의 provider/broker 키 패턴을 추가하세요. 확실할 때 한 번
우회하려면 `git push --no-verify`를 쓰세요.

### playwright-screenshot-guard.sh

Playwright MCP는 자동 명명된 스크린샷을 git-ignore된 `.playwright-mcp/` 디렉터리에 저장하지만 —
**상대** `filename`은 repo 루트 기준으로 해석되어 추적되지 않는 PNG를 그 자리에 남깁니다. 이 가드는
그 한 가지 경우만 거부하고(수정 힌트 포함) 나머지는 통과시킵니다: 파일명 없음, `.playwright-mcp/...`
경로, 또는 임의의 절대 경로. `mcp__.*playwright.*__browser_take_screenshot` 매처에 연결하세요.

---

## 취향 반영 bash 가드 (`hooks/bash-guards/`)

이 가드들은 특정한 작업 스타일(git-worktree 워크플로, 프롬프트 없는 무인 `/loop` 실행,
`Grep`/`Read` 도구로 유도)을 인코딩합니다. 그 습관을 공유한다면 정말 유용하지만 아니면 잡음일
뿐이라 — 코어 훅과 분리해 두었으니 원하는 것만 설치하세요. 각각 exit 2로 차단하며 자기 교정 메시지를
출력하거나(또는 deny/nudge JSON을 내보냄), 파싱 오류 시에는 모두 **fail open**합니다.

| 가드 | 차단 대상 | 이유 |
|-------|--------|-----|
| `git-branch-switch-guard.sh` | **메인** 워크트리에서의 `git checkout/switch <existing-branch>` | 메인 워크트리를 main에 고정하고 `git worktree add` 체크아웃에서 feature 작업을 한다면, 무심코 한 switch가 다른 세션을 방해합니다. `-b`/`--create`, `main`/`master`, 그리고 `.worktree/` cwd 내부의 모든 것은 허용합니다. |
| `xargs-procsub-guard.sh` | `xargs`, 프로세스 치환 `<(...)` | 생성된 one-liner에서 오용하기 쉬워, `for` 루프 / `git diff` / 임시 파일로 유도합니다. 따옴표로 묶인 경우는 무시합니다. |
| `brace-expansion-guard.sh` | 따옴표 없는 brace expansion `{a,b}` / `{1..n}` | 권한 매처가 정적으로 해석할 수 없어 어떤 allow 규칙도 자동 승인하지 못하고 무인 loop가 프롬프트에서 멈춥니다. 따옴표로 묶인 brace / heredoc 본문은 괜찮습니다. |
| `grep-tool-guard.sh` | 따옴표 없는 `grep --include=*glob`(deny); 임시방편 `grep -r`/`find -name`(nudge) | `grep --include=*.py`는 zsh에서 중단됩니다(glob nomatch). `Grep` 도구 / repo-radar로 유도합니다. |
| `compound-cd-guard.sh` | 복합 명령 안의 상대 `cd`(`cd src && …`) | 체인 안의 상대 `cd`는 정적으로 해석 불가(자동 승인 안 됨)이고, 절반만 실행된 `cd <rel> && git merge`는 메인 워크트리를 망가뜨릴 수 있습니다. 절대 경로/`~`/`$VAR`, 그리고 단독 `cd` 하나는 허용합니다. |
| `temp-dir-guard.sh` | `/tmp` / `/var/tmp` / `$TMPDIR`로의 쓰기 | `~/tmp` 스크래치 관례를 강제합니다. `/tmp`에서의 읽기는 여전히 통과합니다. 순수 opt-in — 이 관례를 안 쓰면 건너뛰세요. |

---

## repo-radar (스킬)

원래라면 깨지기 쉬운 셸로 답하던 repo 질문들을 위한 읽기 전용 Python 툴킷입니다: 브랜치 분기 /
fast-forward 가능 여부, 어느 PR이 어디에 머지됐는지, 워크트리 정리 후보, 예측된 머지 충돌(포매팅
전용 vs 논리적), 코드/로그 검색, ref/파일 비교. 모든 질문이 **셸을 거치지 않는 단일 호출**입니다 —
`git`/`gh`/`grep`/`diff`가 Python `subprocess` argv 리스트로 실행되므로 `*.py`, `xargs`, `<(`,
백틱, 줄바꿈이 들어간 패턴도 그냥 문자열일 뿐 zsh나 훅을 건드리지 않습니다.

```
python3 ~/.claude/skills/repo-radar/scripts/radar.py git overview
python3 ~/.claude/skills/repo-radar/scripts/radar.py git diverge main feature-x --json
python3 ~/.claude/skills/repo-radar/scripts/radar.py search code "TODO" --ext py
```

전체 명령 목록은 [`skills/repo-radar/SKILL.md`](skills/repo-radar/SKILL.md)를 참고하세요. 표준
Claude Code 스킬이라 `~/.claude/skills/` 아래에 설치하면(`./install.sh --radar`) Claude가 자동으로
발견합니다.

---

## 훅 자동 승인의 동작 원리 (사실 관계)

- **출력 형식**: PreToolUse 훅은
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",...}}`를
  출력하고 exit 0으로 종료해 승인합니다. `"deny"`는 차단하고, JSON을 생략(exit 0)하면 "의견 없음"
  입니다. exit 2는 stderr를 모델에 되먹이며 강제 차단합니다. (레거시 `{"decision":"approve"}`
  형태는 deprecated입니다.)
- **우선순위**: 여러 훅 사이에서는 exit-2 차단이 이깁니다. 훅의 `"allow"`는 *프롬프트만 건너뛸* 뿐
  settings의 `deny`(또는 `ask`) 규칙을 우회하지 **못합니다**. 따라서 여러분의 deny 목록이 언제나
  넘을 수 없는 최종 기준선입니다.
- **매처**: `.*`(또는 생략)는 MCP 포함 모든 도구에 매칭; `Bash|Read` 같은 파이프 리스트; 나머지는
  정규식(`mcp__.*playwright.*__...`).

## 위협 모델 & 한계

이것은 샌드박스가 아니라 **보안을 의식한 기본값을 갖춘 편의 계층**입니다.

- Bash 검증은 적대적 문법에 대한 텍스트 분석입니다. 의도적으로 보수적이며(알 수 없는 구문은 위임),
  테스트 스위트는 강화 과정에서 발견된 우회 부류들을 인코딩하고 있습니다 — 명령/인자 위치의 `$()`,
  단일 `&` 백그라운딩, 키워드로 가려진 루프 본문, 리다이렉트 쓰기, 플래그 밀반입, `env <cmd>`,
  그리고 레드팀으로 잡아 고친 입력 리다이렉트 처리의 실제 구분자 삼킴 버그(`< f;rm x`). 이 훅은 한
  계층으로만 다루고, `permissions.deny`를 백스톱으로 유지하세요.
- 승인된 읽기 명령은 여전히 여러분의 사용자가 읽을 수 있는 모든 파일을 읽을 수 있습니다 — 그게
  여러분이 선택한 대상입니다. 시크릿 가드는 최악의 경우를 좁혀 주지만 패턴 기반이라(`notes.txt`
  안의 시크릿은 잡지 못합니다).
- `WebFetch`/`browser_navigate`는 실제 네트워크 요청을 보냅니다. URL을 통한 유출이 범위에 있다면
  제거하세요.
- bash-guards는 보안 경계가 아니라 워크플로 취향입니다.

우회를 발견하면 실패하는 테스트 케이스와 함께 이슈를 열어 주세요(`tests/run.sh` /
`tests/guards.test.sh`에 형식이 나와 있습니다).

## 테스트

```
bash tests/run.sh          # 읽기 전용 훅 + 시크릿 읽기 가드 (150+ 케이스)
bash tests/guards.test.sh  # 독립 가드들 (가드별 차단/통과)
```

둘 다 기본 macOS `/bin/bash` 3.2와 최신 Linux bash에서 동작합니다. `jq`(+ 가드 스위트에는
`python3`)가 필요합니다.

## 라이선스

MIT
