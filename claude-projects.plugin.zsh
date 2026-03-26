# zsh-claude-projects — browse & resume Claude Code sessions via fzf
# Usage: p [-d]
# Set ZSH_CLAUDE_PROJECTS_ALIAS to change the command name (default: p)

# Cache binary paths at source time.
# zsh loses its command hash table inside `while read <<< herestring`,
# so every external tool must be resolved up front.
typeset -g _CP_CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")
typeset -g _CP_JQ=$(command -v jq 2>/dev/null)
typeset -g _CP_FZF=$(command -v fzf 2>/dev/null)
typeset -g _CP_SORT=$(command -v sort 2>/dev/null || echo /usr/bin/sort)
typeset -g _CP_AWK=$(command -v awk 2>/dev/null || echo /usr/bin/awk)
typeset -g _CP_DATE=$(command -v date 2>/dev/null || echo /usr/bin/date)
typeset -g _CP_TAIL=$(command -v tail 2>/dev/null || echo /usr/bin/tail)
typeset -g _CP_RM=$(command -v rm 2>/dev/null || echo /bin/rm)
typeset -g _CP_MKTEMP=$(command -v mktemp 2>/dev/null || echo /usr/bin/mktemp)

_cp_check_deps() {
  local missing=()
  [[ -n "$_CP_JQ"  && -x "$_CP_JQ"  ]] || missing+=(jq)
  [[ -n "$_CP_FZF" && -x "$_CP_FZF" ]] || missing+=(fzf)
  if (( ${#missing[@]} )); then
    echo "zsh-claude-projects: missing deps: ${missing[*]}" >&2
    echo "  brew install ${missing[*]}" >&2
    return 1
  fi
}

_cp_encode() { echo "${1//\//-}"; }

# Extract one display row per session jsonl file:
#   timestamp \t sessionId \t slug \t preview
_cp_session_row() {
  local jsonl="$1" sid_file="$2"

  local file_slug
  file_slug=$("$_CP_JQ" -r 'select(.slug != null and .slug != "") | .slug' "$jsonl" 2>/dev/null | "$_CP_TAIL" -1)

  local line c=0 out ts sid preview
  while IFS= read -r line && (( c++ < 100 )); do
    [[ -z "$line" ]] && continue
    out=$(
      printf '%s\n' "$line" | "$_CP_JQ" -r '
        select(.type == "user" and (.isMeta != true)) |
        (.message.content
          | if type == "string" then .
            elif type == "array" then (.[0].text // "")
            else "" end) as $txt |
        select(
          ($txt | startswith("<local-command") | not)
          and ($txt | startswith("<command") | not)
          and ($txt | length > 0)
        ) |
        [.timestamp, (.sessionId // ""),
         ($txt | if length > 60 then .[0:60] else . end)
        ] | @tsv' 2>/dev/null
    ) || true
    [[ -z "$out" ]] && continue
    IFS=$'\t' read -r ts sid preview <<< "$out"
    [[ -z "$sid" ]] && sid="$sid_file"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$sid" "$file_slug" "$preview"
    return 0
  done < "$jsonl"

  local mt
  mt=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$jsonl" 2>/dev/null \
    || "$_CP_DATE" -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s\t%s\t%s\t\n' "$mt" "$sid_file" "$file_slug"
}

_cp_sessions() {
  local proj_dir="$HOME/.claude/projects/$(_cp_encode "$1")"
  [[ -d "$proj_dir" ]] || return 0
  local jsonl sid
  for jsonl in "$proj_dir"/*.jsonl(N.Om[1,10]); do
    sid="${jsonl:t:r}"
    [[ "$sid" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]] || continue
    _cp_session_row "$jsonl" "$sid"
  done
}

_cp_build_list() {
  local history="$HOME/.claude/history.jsonl"
  [[ -f "$history" ]] || { echo "zsh-claude-projects: ~/.claude/history.jsonl not found" >&2; return 1; }

  local projects
  projects=$(
    "$_CP_JQ" -r 'select(.project != null and .project != "") | [(.timestamp|tostring), .project] | join("\t")' "$history" \
      | "$_CP_SORT" -t$'\t' -k1 -rn \
      | "$_CP_AWK" -F'\t' '!seen[$2]++ { print $2 }' \
      | while IFS= read -r p; do [[ -d "$p" ]] && echo "$p"; done
  )

  local path short n f sessions_data sess_lines i count
  local ts sid slug preview date_str label branch disp
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    short="${path#$HOME/}"
    [[ "$short" == "$path" ]] && short="${path%/}/" || short="${short%/}/"

    n=0
    for f in "$HOME/.claude/projects/$(_cp_encode "$path")"/*.jsonl(N); do
      [[ "${f:t:r}" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]] && (( n++ ))
    done

    printf " \033[1;36m%-48s\033[0m  \033[2m%d sessions\033[0m\tP\t%s\n" "$short" "$n" "$path"

    sessions_data=$(_cp_sessions "$path")
    [[ -z "$sessions_data" ]] && continue

    sess_lines=("${(@f)sessions_data}")
    count=${#sess_lines[@]}
    for (( i = 1; i <= count; i++ )); do
      IFS=$'\t' read -r ts sid slug preview <<< "${sess_lines[i]}"
      [[ -z "$sid" ]] && continue
      ts="${ts//$'\r'/}"; ts="${ts//$'\n'/}"
      date_str=$(
        "$_CP_DATE" -j -f "%Y-%m-%dT%H:%M:%S" "${ts%.*}" "+%m/%d %H:%M" 2>/dev/null \
          || echo "${ts:5:16}"
      )
      if [[ -n "$slug" ]]; then
        label=$'\e[1m'"${slug}"$'\e[0m'
      else
        label=$'\e[2;3m[No Slug]\e[0m'
      fi
      [[ -n "$preview" ]] && label+=$'  \e[2m'"${preview}"$'\e[0m'
      (( i == count )) && branch=$'\e[2m└─\e[0m' || branch=$'\e[2m├─\e[0m'
      disp="   ${branch}  "$'\e[2m'"${date_str}"$'\e[0m  '"${label}"
      printf "%s\tS\t%s\t%s\n" "$disp" "$path" "$sid"
    done
  done <<< "$projects"
}

_cp_main() {
  _cp_check_deps || return 1

  local dangerous=0
  [[ "$1" == "-d" ]] && dangerous=1

  local fzf_prompt="  Claude > " fzf_opts=()
  if (( dangerous )); then
    fzf_prompt="  Claude [DANGEROUS] > "
    fzf_opts+=(--color=prompt:red,border:red)
  fi

  local _cp_act_file
  _cp_act_file=$("$_CP_MKTEMP")

  local selected
  selected=$(
    _cp_build_list | "$_CP_FZF" \
      --ansi \
      --no-multi \
      --delimiter=$'\t' \
      --with-nth=1 \
      --prompt="$fzf_prompt" \
      --header="  Enter: 打开  │  Ctrl-D: 删除 Session  │  Esc: 取消" \
      --height=60% \
      --reverse \
      --border=rounded \
      --info=inline \
      --bind="ctrl-d:execute-silent(printf ctrl-d > '$_cp_act_file')+accept" \
      --bind="esc:abort" \
      "${fzf_opts[@]}"
  )

  local key=""
  [[ -f "$_cp_act_file" ]] && key=$(< "$_cp_act_file")
  "$_CP_RM" -f "$_cp_act_file"

  [[ -z "$selected" ]] && return 0

  local action_line="$selected"

  if [[ "$key" == "ctrl-d" ]]; then
    local tag path session_id
    IFS=$'\t' read -r _ tag path session_id <<< "$action_line"
    if [[ "$tag" == "S" && -n "$session_id" ]]; then
      local jsonl="$HOME/.claude/projects/$(_cp_encode "$path")/${session_id}.jsonl"
      if [[ -f "$jsonl" ]]; then
        printf "删除 session %s? [y/N] " "${session_id:0:8}"
        read -r -k1 confirm; echo
        [[ "$confirm" == [yY] ]] && "$_CP_RM" -f "$jsonl" && echo "已删除。" && _cp_main
      fi
    else
      echo "只能删除 session，不能删除项目。"
    fi
    return 0
  fi

  local claude_args=()
  (( dangerous )) && claude_args+=(--dangerously-skip-permissions)

  local tag path session_id
  IFS=$'\t' read -r _ tag path session_id <<< "$action_line"
  cd "$path" || return 1
  if [[ "$tag" == "S" && -n "$session_id" ]]; then
    "$_CP_CLAUDE" -r "$session_id" "${claude_args[@]}"
  else
    "$_CP_CLAUDE" "${claude_args[@]}"
  fi
}

alias "${ZSH_CLAUDE_PROJECTS_ALIAS:-p}"='_cp_main'
