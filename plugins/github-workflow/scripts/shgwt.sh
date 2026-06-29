#!/usr/bin/env bash
# shgwt.sh — 자기완결 git worktree spawn/teardown 헬퍼.
#
# github-workflow 스킬의 claude-cleanup-worktree 가 teardown 에 위임한다.
# 외부 의존성 없이 git 만으로 동작하도록 작성됐다.
#
# 사용:
#   bash shgwt.sh spawn <name> [--base <ref>]
#   bash shgwt.sh teardown [--force] [--keep-branch]
#   bash shgwt.sh -h
#
# 동작:
#   - 워크트리 위치: <repo>/.claude/worktrees/<name>-<N>
#     (Claude Code harness 의 --worktree / Agent isolation 이 만드는
#      <repo>/.claude/worktrees/<name> 과 부모 디렉토리를 공유한다.
#      브랜치 prefix 는 harness 가 worktree-*, shgwt 가 wt/* 로 갈려 충돌 없음.)
#   - 브랜치 = wt/<name>/<N> 고정
#
# source 시 함수만 정의하고 dispatch 하지 않으므로 단위 테스트에서 헬퍼만
# 분리해 검증할 수 있다 (test-shgwt.sh 참고).
# `set -euo pipefail` 은 직접 실행 분기 안에서만 적용한다 — source 시
# 호출자 셸의 옵션을 오염시키지 않기 위함.

# ────────────────────────────────────────────────────────────────────
# 출력 헬퍼 — ✅/❌/⚠️ 스타일
# ────────────────────────────────────────────────────────────────────
shgwt_info() { printf 'ℹ️  %s\n' "$*"; }
shgwt_ok()   { printf '✅ %s\n' "$*"; }
shgwt_warn() { printf '⚠️  %s\n' "$*" >&2; }
shgwt_err()  { printf '❌ %s\n' "$*" >&2; }

shgwt_usage() {
  cat <<'EOF'
shgwt — 자기완결 git worktree 헬퍼

Usage:
  shgwt spawn <name> [--base <ref>]
      <repo>/.claude/worktrees/<name>-<N> 에 워크트리를 만들고
      wt/<name>/<N> 브랜치를 새로 판다. 메인 레포에서만 실행 가능.

  shgwt teardown [--force] [--keep-branch]
      현재 들어가 있는 워크트리를 제거하고, 메인 레포에서 main 을
      origin/main 기준 ff-only 동기화한 뒤 워크트리 브랜치를 삭제.

옵션:
  --base <ref>     spawn 의 베이스 ref
                   (기본: origin/HEAD → origin/main → main → HEAD)
  --force          teardown 시 미커밋/미푸시 변경을 무시하고 강제 정리
  --keep-branch    teardown 시 브랜치를 지우지 않고 보존
  -h, --help       이 도움말
EOF
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 이름 검사 ('/' 와 공백 금지, '-' 시작 금지, 빈 문자열 금지)
# ────────────────────────────────────────────────────────────────────
shgwt_validate_name() {
  local name="${1-}"
  if [[ -z "$name" ]]; then
    shgwt_err "<name>이 필요합니다."
    return 1
  fi
  case "$name" in
    issue)
      shgwt_err "'issue' 는 claude-enter-issue 가 쓰는 예약어입니다."
      shgwt_info "이슈 워크트리를 만들려면: claude-enter-issue <N>"
      return 1
      ;;
    -* | */* | *" "*)
      shgwt_err "잘못된 이름: '$name' ('/' 공백 금지, '-' 로 시작 금지)"
      return 1
      ;;
  esac
  return 0
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — 위치 판정
#   0 = 메인 레포, 1 = 워크트리 내부, 2 = git 저장소 아님
# git-dir 과 git-common-dir 의 절대경로(pwd -P)를 비교.
# ────────────────────────────────────────────────────────────────────
shgwt_in_main_repo() {
  local common dir common_abs dir_abs
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 2
  dir="$(git rev-parse --git-dir 2>/dev/null)" || return 2
  common_abs="$(cd "$common" 2>/dev/null && pwd -P)" || return 2
  dir_abs="$(cd "$dir" 2>/dev/null && pwd -P)" || return 2
  [[ "$common_abs" == "$dir_abs" ]] && return 0
  return 1
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — .claude/worktrees/<name>-<N> 중 다음 N
# ────────────────────────────────────────────────────────────────────
shgwt_next_index() {
  local root="$1" name="$2"
  local next=1 dir n
  for dir in "${root}/.claude/worktrees/${name}-"*/; do
    [[ -d "$dir" ]] || continue
    n="${dir%/}"
    n="${n##*-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if ((n >= next)); then
      next=$((n + 1))
    fi
  done
  printf '%s\n' "$next"
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — base 자동 선택
# ────────────────────────────────────────────────────────────────────
shgwt_default_base() {
  # Claude Code harness 정합성 (#122):
  # harness 는 clone 시 설정된 origin/HEAD 를 base 로 쓴다. shgwt 도 1순위를
  # origin/HEAD 로 맞춰 두 도구가 같은 ref 를 출발점으로 삼도록 한다.
  # origin/HEAD 가 없는 로컬(오래된 clone 등)에서는 기존 fallback 유지.
  if git rev-parse --verify --quiet "origin/HEAD" >/dev/null 2>&1; then
    printf 'origin/HEAD\n'
  elif git rev-parse --verify --quiet "origin/main" >/dev/null 2>&1; then
    printf 'origin/main\n'
  elif git rev-parse --verify --quiet "main" >/dev/null 2>&1; then
    printf 'main\n'
  else
    printf 'HEAD\n'
  fi
}

# ────────────────────────────────────────────────────────────────────
# 헬퍼 — HEAD 가 안전하게 폐기 가능한가 (commits_safe)
# 원본 _gwt_commits_safe 의 축약 포팅:
#   1) upstream 과 정확히 일치
#   2) HEAD 가 main_ref 의 조상
#   3) git cherry 결과에 '+' 가 없음 (rebase/squash merge 후)
#   4) upstream 미설정 + main_ref 대비 ahead == 0
#
# main_ref 는 origin/HEAD 를 1순위로 선택 (shgwt_default_base 와 동일 정책).
# default branch 가 main 이 아닌 레포에서도 safety check 이 올바른 기준
# ref 를 사용하도록 한다 (#122 리뷰 피드백).
# ────────────────────────────────────────────────────────────────────
shgwt_commits_safe() {
  local local_rev remote_rev main_ref
  local_rev="$(git rev-parse HEAD)"
  remote_rev="$(git rev-parse '@{u}' 2>/dev/null || echo "no-upstream")"
  if [[ "$remote_rev" != "no-upstream" && "$local_rev" == "$remote_rev" ]]; then
    return 0
  fi
  main_ref="origin/HEAD"
  git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1 || main_ref="origin/main"
  git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1 || main_ref="origin/master"
  git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1 || main_ref="main"
  git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1 || main_ref="master"
  if git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1; then
    if git merge-base --is-ancestor HEAD "$main_ref" 2>/dev/null; then
      return 0
    fi
    # cherry 실패(ref 없음 등)를 안전하게 처리: 실패 시 '+' 로 간주하여 unsafe.
    local cherry_out
    cherry_out="$(git cherry "$main_ref" HEAD 2>/dev/null)" || cherry_out="+"
    [[ "$cherry_out" != *"+"* ]] && return 0
  fi
  if [[ "$remote_rev" == "no-upstream" ]]; then
    local ahead
    ahead="$(git rev-list --count "${main_ref}..HEAD" 2>/dev/null || echo 999)"
    [[ "$ahead" == "0" ]] && return 0
  fi
  return 1
}

# ────────────────────────────────────────────────────────────────────
# spawn — .worktrees/<name>-<N> 워크트리 생성
# ────────────────────────────────────────────────────────────────────
shgwt_spawn() {
  local name="" base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        shgwt_usage
        return 0
        ;;
      --base)
        if [[ $# -lt 2 ]]; then
          shgwt_err "--base 뒤에 ref 가 필요합니다."
          return 1
        fi
        base="$2"
        shift 2
        ;;
      -*)
        shgwt_err "알 수 없는 옵션: $1"
        return 1
        ;;
      *)
        if [[ -n "$name" ]]; then
          shgwt_err "이름이 두 개 이상입니다: '$name', '$1'"
          return 1
        fi
        name="$1"
        shift
        ;;
    esac
  done

  shgwt_validate_name "$name" || return 1

  # `|| mr_status=$?` 패턴: set -e 하에서 함수 반환값을 안전하게 캡처
  local mr_status=0
  shgwt_in_main_repo || mr_status=$?
  if [[ $mr_status -eq 1 ]]; then
    shgwt_err "워크트리 안에서는 spawn 할 수 없습니다. 메인 레포에서 실행하세요."
    return 1
  elif [[ $mr_status -eq 2 ]]; then
    shgwt_err "git 저장소가 아닙니다."
    return 1
  fi

  local root
  root="$(git rev-parse --show-toplevel)"
  [[ -z "$base" ]] && base="$(shgwt_default_base)"

  local idx wt_path branch
  idx="$(shgwt_next_index "$root" "$name")"
  wt_path="${root}/.claude/worktrees/${name}-${idx}"
  branch="wt/${name}/${idx}"

  mkdir -p "${root}/.claude/worktrees"

  if ! git worktree add -b "$branch" "$wt_path" "$base"; then
    shgwt_err "git worktree add 실패: $wt_path"
    return 1
  fi

  shgwt_ok "Worktree 생성 완료"
  shgwt_info "  Path:   $wt_path"
  shgwt_info "  Branch: $branch"
  shgwt_info "  Base:   $base"
  shgwt_info ""
  shgwt_info "  cd $wt_path"
}

# ────────────────────────────────────────────────────────────────────
# teardown — 현재 워크트리 정리 + main 동기화 + 브랜치 삭제
# ────────────────────────────────────────────────────────────────────
shgwt_teardown() {
  local force=false keep_branch=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        shgwt_usage
        return 0
        ;;
      --force) force=true; shift ;;
      --keep-branch) keep_branch=true; shift ;;
      -*)
        shgwt_err "알 수 없는 옵션: $1"
        return 1
        ;;
      *)
        shgwt_err "teardown 은 위치 인자를 받지 않습니다: '$1'"
        shgwt_info "  현재 들어가 있는 워크트리를 자기 자신이 정리하는 명령입니다."
        return 1
        ;;
    esac
  done

  local mr_status=0
  shgwt_in_main_repo || mr_status=$?
  if [[ $mr_status -eq 0 ]]; then
    shgwt_err "메인 레포입니다. teardown 은 워크트리 내부에서 실행하세요."
    return 1
  elif [[ $mr_status -eq 2 ]]; then
    shgwt_err "git 저장소가 아닙니다."
    return 1
  fi

  # git diff 는 untracked 를 못 잡는데 git worktree remove 는 untracked 가 있으면
  # 실패한다. 두 경우 모두 한 번에 잡기 위해 git status --porcelain 사용.
  if [[ -n "$(git status --porcelain)" ]]; then
    if [[ "$force" == true ]]; then
      shgwt_warn "미커밋 변경(untracked 포함)을 폐기합니다 (--force)"
    else
      shgwt_err "미커밋 변경이나 untracked 파일이 있습니다. 커밋/스태시 하거나 --force 를 쓰세요."
      return 1
    fi
  fi

  git fetch origin >/dev/null 2>&1 || shgwt_warn "git fetch 실패 — merged 판정이 stale 할 수 있습니다."

  if ! shgwt_commits_safe; then
    if [[ "$force" == true ]]; then
      shgwt_warn "미푸시 커밋을 폐기합니다 (--force)"
    else
      local cur main_ref ahead
      cur="$(git rev-parse --abbrev-ref HEAD)"
      main_ref="origin/HEAD"
      git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1 || main_ref="origin/main"
      git rev-parse --verify --quiet "$main_ref" >/dev/null 2>&1 || main_ref="origin/master"
      ahead="$(git rev-list --count "${main_ref}..HEAD" 2>/dev/null || echo "?")"
      shgwt_err "'${cur}' 에 미푸시 커밋이 있습니다 (${main_ref} 대비 ${ahead} ahead)."
      shgwt_info "  Push:  git push -u origin $cur"
      shgwt_info "  Or:    bash scripts/shgwt.sh teardown --force   # 폐기"
      return 1
    fi
  fi

  local wt_path branch git_common main_repo
  wt_path="$(git rev-parse --show-toplevel)"
  branch="$(git rev-parse --abbrev-ref HEAD)"
  git_common="$(git rev-parse --git-common-dir)"
  main_repo="$(cd "$git_common" && cd .. && pwd -P)"

  case "$branch" in
    main | master | HEAD)
      shgwt_err "현재 브랜치 '$branch' 는 보호 대상입니다. teardown 거부."
      return 1
      ;;
  esac

  cd "$main_repo" || {
    shgwt_err "메인 레포로 cd 실패: $main_repo"
    return 1
  }

  # 단일 호출로 통합: git 자체 에러 메시지(잠김 등)를 그대로 노출해 디버깅을 돕는다.
  local remove_args=("$wt_path")
  [[ "$force" == true ]] && remove_args=(--force "$wt_path")
  if ! git worktree remove "${remove_args[@]}"; then
    return 1
  fi
  git worktree prune

  local main_branch="main"
  git rev-parse --verify --quiet "main" >/dev/null 2>&1 || main_branch="master"

  local main_sync_ok=true
  if ! git checkout -q "$main_branch" 2>/dev/null; then
    shgwt_warn "checkout $main_branch 실패 — 메인 레포 정리는 수동으로."
    main_sync_ok=false
  elif git rev-parse --verify --quiet "origin/$main_branch" >/dev/null 2>&1; then
    if ! git merge --ff-only "origin/$main_branch" >/dev/null 2>&1; then
      main_sync_ok=false
      shgwt_warn "ff-only 동기화 실패 — 로컬 $main_branch 가 origin 과 갈라졌습니다."
    fi
  else
    main_sync_ok=false
    shgwt_warn "origin/$main_branch 미발견 — sync 건너뜀."
  fi

  if [[ "$keep_branch" == true ]]; then
    shgwt_info "브랜치 보존: $branch (--keep-branch)"
  elif git branch -d "$branch" 2>/dev/null; then
    shgwt_ok "브랜치 삭제: $branch"
  elif [[ "$force" == true ]]; then
    git branch -D "$branch" 2>/dev/null || true
    shgwt_ok "브랜치 강제 삭제: $branch"
  else
    shgwt_warn "브랜치 '$branch' 가 fully merged 가 아닙니다. --force 또는 --keep-branch 를 쓰세요."
  fi

  if [[ "$main_sync_ok" == true ]]; then
    shgwt_ok "Teardown 완료"
    shgwt_info "  Removed: $wt_path"
    shgwt_info "  Now on:  $main_branch ($main_repo)"
    shgwt_info "  ※ 호출 셸의 PWD 가 제거된 디렉토리이면: cd $main_repo"
    return 0
  fi

  shgwt_warn "Teardown 부분 완료 — 워크트리는 제거됐으나 main 은 origin 과 미동기화"
  shgwt_info "  Removed: $wt_path"
  shgwt_info "  Now on:  $main_branch (out of sync, $main_repo)"
  return 1
}

# ────────────────────────────────────────────────────────────────────
# Dispatcher
# ────────────────────────────────────────────────────────────────────
shgwt_dispatch() {
  case "${1:-}" in
    spawn)
      shift
      shgwt_spawn "$@"
      ;;
    teardown)
      shift
      shgwt_teardown "$@"
      ;;
    -h | --help | help)
      shgwt_usage
      return 0
      ;;
    "")
      shgwt_usage
      return 1
      ;;
    *)
      shgwt_err "알 수 없는 명령: $1"
      shgwt_usage
      return 1
      ;;
  esac
}

# 직접 실행 시에만 dispatch. source 시에는 함수 정의만 노출 (테스트 용).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  shgwt_dispatch "$@"
fi
