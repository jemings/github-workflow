---
name: hud
license: Apache-2.0
description: >-
  현재 환경에 설정된 Claude Code statusline을 다른 새 환경에도 동일하게
  설치한다. /hud 또는 "statusline 설치해줘", "새 환경에 statusline 셋업",
  "hud 설치", "statusline 복제/옮겨줘"처럼 statusline 설치·복제를 요청하면
  트리거하라.
allowed-tools: Bash, Read
---

# hud — statusline 빠른 셋업

## Role

`scripts/install.sh`가 두 statusline 스크립트를 `~/.claude/`에 배치하고
`~/.claude/settings.json`의 `statusLine` 필드를 병합한다. 결과는 모델명 ·
작업 디렉터리(git 브랜치 포함) · 컨텍스트 사용률 · 5시간 한도 사용률(`/usage`의
"Current session"과 동일 값, 임계값별 색상) · 세션 누적 토큰(↑입력/캐시,
↓출력)을 한 줄로 보여주는 statusline이다. 5시간 한도 세그먼트는 claude.ai
구독 계정에만 표시되며, API 키 세션에서는 생략된다.

## Run

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/hud/scripts/install.sh"
```

성공·실패 원인과 조치는 stdout/stderr에 그대로 나온다(성공 시 샘플 렌더,
실패 시 원인 메시지). 기존 스크립트가 설치할 내용과 다르면 diff를 경고로
보여준 뒤 덮어쓴다.

## Notes

세션 누적 토큰 세그먼트(↑/↓)는 `~/.cache/claude-statusline/`에 transcript별
캐시·baseline 파일을 둔다 — 설치 시점에는 생성되지 않고 첫 실제 렌더에서
자동 생성된다.
