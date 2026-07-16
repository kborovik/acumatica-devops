#!/bin/sh
# Claude Code statusline: dir | branch | git counts

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')
[ -z "$cwd" ] && cwd=$(pwd)

dir=$(basename "$cwd")

if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  porcelain=$(git -C "$cwd" -c core.fsmonitor= status --porcelain 2>/dev/null)

  staged=0
  changed=0
  untracked=0
  ahead=0
  behind=0

  if upstream=$(git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    counts=$(git -C "$cwd" rev-list --count --left-right "${upstream}...HEAD" 2>/dev/null)
    if [ -n "$counts" ]; then
      behind=${counts%%	*}
      ahead=${counts##*	}
    fi
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    x=${line%${line#?}}   # index (col 1)
    y=${line#?}; y=${y%${y#?}}  # worktree (col 2)

    if [ "$x" = "?" ] && [ "$y" = "?" ]; then
      untracked=$((untracked + 1))
    else
      [ "$x" != " " ] && staged=$((staged + 1))
      [ "$y" != " " ] && changed=$((changed + 1))
    fi
  done <<EOF
$porcelain
EOF

  # Catppuccin Macchiato — match fish __fish_git_prompt_color_* settings
  CWD='\033[38;2;238;212;159m'      # yellow  eed49f
  BRANCH='\033[38;2;139;213;202m'   # teal    8bd5ca
  UPSTREAM='\033[38;2;138;173;244m' # blue    8aadf4
  DIRTY='\033[38;2;237;135;150m'    # red     ed8796
  UNTRACKED='\033[38;2;198;160;246m' # mauve  c6a0f6
  STAGED='\033[38;2;166;218;149m'   # green   a6da95
  CLEAN='\033[38;2;166;218;149m'    # green   a6da95
  RESET='\033[0m'

  out="${CWD}${dir}${RESET}  ${BRANCH}${branch}${RESET}"
  [ "$ahead" -gt 0 ] && out="${out}  ${UPSTREAM}↑${ahead}${RESET}"
  [ "$behind" -gt 0 ] && out="${out}  ${UPSTREAM}↓${behind}${RESET}"
  [ "$staged" -gt 0 ] && out="${out}  ${STAGED}+${staged}${RESET}"
  [ "$changed" -gt 0 ] && out="${out}  ${DIRTY}!${changed}${RESET}"
  [ "$untracked" -gt 0 ] && out="${out}  ${UNTRACKED}^${untracked}${RESET}"
  if [ "$staged" -eq 0 ] && [ "$changed" -eq 0 ] && [ "$untracked" -eq 0 ]; then
    out="${out}  ${CLEAN}✓${RESET}"
  fi
  printf "%b" "$out"
else
  CWD='\033[38;2;238;212;159m'
  RESET='\033[0m'
  printf "${CWD}%s${RESET}" "$dir"
fi
