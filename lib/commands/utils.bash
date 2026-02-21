#!/usr/bin/env bash

command_utils() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu _utils <subcommand>" >&2
    exit 1
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
    pretty_claude_stream_json)
      command_utils_pretty_claude_stream_json "$@"
      ;;
    *)
      echo "aijigu _utils: unknown subcommand '${subcommand}'" >&2
      exit 1
      ;;
  esac
}

# ANSI color codes
_PCSJ_RST=$'\e[0m'
_PCSJ_BOLD=$'\e[1m'
_PCSJ_DIM=$'\e[2m'
_PCSJ_RED=$'\e[31m'
_PCSJ_GREEN=$'\e[32m'
_PCSJ_YELLOW=$'\e[33m'
_PCSJ_BLUE=$'\e[34m'
_PCSJ_CYAN=$'\e[36m'

# Show lines from stdin, truncating after max_lines
_pcsj_show_lines() {
  local max_lines="${1:-10}"
  local lines=()
  while IFS= read -r l; do
    lines+=("$l")
  done
  local total=${#lines[@]}
  if [[ $total -eq 0 ]]; then return; fi
  local show=$((total > max_lines ? max_lines : total))
  for ((i = 0; i < show; i++)); do
    printf '%s     %s%s\n' "$_PCSJ_DIM" "${lines[$i]}" "$_PCSJ_RST"
  done
  if ((total > max_lines)); then
    printf '%s     ... (%d more lines)%s\n' "$_PCSJ_DIM" "$((total - max_lines))" "$_PCSJ_RST"
  fi
}

# Format tool input summary for a given tool name
# Args: $1=name, $2=input (compact JSON)
_pcsj_tool_input() {
  local name="$1"
  local input="$2"

  case "$name" in
    Read|Write|Edit)
      printf ' %s%s%s' "$_PCSJ_DIM" "$(printf '%s' "$input" | jq -r '.file_path // ""')" "$_PCSJ_RST"
      ;;
    Glob)
      printf ' %s%s%s' "$_PCSJ_DIM" "$(printf '%s' "$input" | jq -r '.pattern // ""')" "$_PCSJ_RST"
      ;;
    Grep)
      printf ' %s%s%s' "$_PCSJ_DIM" \
        "$(printf '%s' "$input" | jq -r '"\(.pattern // "") (\(.path // "."))"')" "$_PCSJ_RST"
      ;;
    Bash)
      printf ' %s%s%s' "$_PCSJ_DIM" \
        "$(printf '%s' "$input" | jq -r '.command // "" | .[0:120]')" "$_PCSJ_RST"
      ;;
    Task)
      printf ' %s%s%s' "$_PCSJ_DIM" \
        "$(printf '%s' "$input" | jq -r '.description // (.prompt // "" | .[0:60])')" "$_PCSJ_RST"
      ;;
    *)
      local summary
      summary=$(printf '%s' "$input" | jq -r \
        'to_entries | map("\(.key)=\(.value | tostring | .[0:40])") | join(" ")')
      if [[ -n "$summary" ]]; then
        printf ' %s%s%s' "$_PCSJ_DIM" "$summary" "$_PCSJ_RST"
      fi
      ;;
  esac
}

# Format a structured tool result object
# Args: $1=result (compact JSON)
_pcsj_tool_result() {
  local result="$1"

  # Determine which branch to take
  local branch
  branch=$(printf '%s' "$result" | jq -r '
    if type != "object" then "raw"
    elif .stdout != null then "stdout"
    elif .filenames != null then "filenames"
    elif .file != null then "file"
    elif .content != null then "content"
    else "keys"
    end
  ' 2>/dev/null) || branch="raw"

  case "$branch" in
    stdout)
      printf '%s' "$result" | jq -r '.stdout // ""' | _pcsj_show_lines 10
      ;;
    filenames)
      local count
      count=$(printf '%s' "$result" | jq -r '.filenames | length')
      printf '%s     %s file(s) found%s\n' "$_PCSJ_DIM" "$count" "$_PCSJ_RST"
      ;;
    file)
      local path num_lines
      path=$(printf '%s' "$result" | jq -r '.file.filePath // ""')
      num_lines=$(printf '%s' "$result" | jq -r '.file.numLines // "?"')
      printf '%s     [%s lines] %s%s\n' "$_PCSJ_DIM" "$num_lines" "$path" "$_PCSJ_RST"
      ;;
    content)
      local ctype
      ctype=$(printf '%s' "$result" | jq -r '.content | type')
      if [[ "$ctype" == "array" ]]; then
        printf '%s' "$result" | jq -r '.content[] | select(.type == "text") | .text // ""' \
          | _pcsj_show_lines 10
      else
        printf '%s' "$result" | jq -r '.content | tostring' | _pcsj_show_lines 10
      fi
      ;;
    keys)
      local keys
      keys=$(printf '%s' "$result" | jq -r 'keys | join(", ")')
      printf '%s     result keys: %s%s\n' "$_PCSJ_DIM" "$keys" "$_PCSJ_RST"
      ;;
    raw)
      printf '%s     %s%s\n' "$_PCSJ_DIM" "${result:0:200}" "$_PCSJ_RST"
      ;;
  esac

  # Show stderr if present
  local stderr
  stderr=$(printf '%s' "$result" | jq -r '
    if (.is_error == true) or ((.stderr // "") | length > 0)
    then .stderr // ""
    else empty
    end
  ' 2>/dev/null) || true
  if [[ -n "${stderr:-}" ]]; then
    printf '%s     stderr: %s%s\n' "$_PCSJ_RED" "${stderr:0:200}" "$_PCSJ_RST"
  fi
}

_pcsj_system() {
  local line="$1"
  local subtype
  subtype=$(printf '%s' "$line" | jq -r '.subtype // ""')
  if [[ "$subtype" == "init" ]]; then
    local info
    info=$(printf '%s' "$line" | jq -r '"\(.model // "unknown")\t\(.session_id // "?" | .[0:8])"')
    local model session
    IFS=$'\t' read -r model session <<< "$info"
    printf '%s=== Session Start ===%s\n' "${_PCSJ_BOLD}${_PCSJ_CYAN}" "$_PCSJ_RST"
    printf '%s  model: %s  session: %s%s\n' "$_PCSJ_DIM" "$model" "$session" "$_PCSJ_RST"
  else
    printf '%s[system] %s%s\n' "$_PCSJ_DIM" "$subtype" "$_PCSJ_RST"
  fi
}

_pcsj_assistant() {
  local line="$1"
  printf '%s' "$line" | jq -c '.message.content // [] | .[]' 2>/dev/null | while IFS= read -r item; do
    local ctype
    ctype=$(printf '%s' "$item" | jq -r '.type // ""')
    case "$ctype" in
      text)
        local text
        text=$(printf '%s' "$item" | jq -r '.text // ""' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$text" ]]; then
          printf '%sClaude:%s\n' "${_PCSJ_BOLD}${_PCSJ_GREEN}" "$_PCSJ_RST"
          while IFS= read -r l; do printf '  %s\n' "$l"; done <<< "$text"
        fi
        ;;
      tool_use)
        local name input_json detail
        name=$(printf '%s' "$item" | jq -r '.name // ""')
        input_json=$(printf '%s' "$item" | jq -c '.input // {}')
        detail=$(_pcsj_tool_input "$name" "$input_json")
        printf '%s  -> %s%s%s\n' "${_PCSJ_BOLD}${_PCSJ_YELLOW}" "$name" "$_PCSJ_RST" "$detail"
        ;;
    esac
  done
}

_pcsj_user() {
  local line="$1"
  printf '%s' "$line" | jq -c '.message.content // [] | .[]' 2>/dev/null | while IFS= read -r item; do
    local ctype
    ctype=$(printf '%s' "$item" | jq -r '.type // ""')
    case "$ctype" in
      tool_result)
        local has_result
        has_result=$(printf '%s' "$line" | jq 'has("tool_use_result")')
        if [[ "$has_result" == "true" ]]; then
          local result_data
          result_data=$(printf '%s' "$line" | jq -c '.tool_use_result')
          _pcsj_tool_result "$result_data"
        else
          local text
          text=$(printf '%s' "$item" | jq -r '
            .content // "" |
            if type == "array" then map(select(.type == "text") | .text // "") | join("\n")
            else tostring
            end
          ')
          if [[ -n "$text" ]]; then
            echo "$text" | _pcsj_show_lines 10
          fi
        fi
        ;;
      text)
        local text
        text=$(printf '%s' "$item" | jq -r '.text // ""' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$text" ]]; then
          printf '%sUser:%s\n' "${_PCSJ_BOLD}${_PCSJ_BLUE}" "$_PCSJ_RST"
          while IFS= read -r l; do printf '  %s\n' "$l"; done <<< "$text"
        fi
        ;;
    esac
  done
}

_pcsj_result() {
  local line="$1"
  local is_error
  is_error=$(printf '%s' "$line" | jq -r '.is_error // false')

  echo ""
  if [[ "$is_error" == "true" ]]; then
    printf '%s=== ERROR ===%s\n' "${_PCSJ_BOLD}${_PCSJ_RED}" "$_PCSJ_RST"
  else
    printf '%s=== Complete ===%s\n' "${_PCSJ_BOLD}${_PCSJ_GREEN}" "$_PCSJ_RST"
  fi

  local result_text
  result_text=$(printf '%s' "$line" | jq -r '.result // ""')
  if [[ -n "$result_text" ]]; then
    printf '%sResult:%s\n' "$_PCSJ_BOLD" "$_PCSJ_RST"
    while IFS= read -r l; do printf '  %s\n' "$l"; done <<< "$result_text"
  fi

  local stats
  stats=$(printf '%s' "$line" | jq -r '
    [
      (if .num_turns then "\(.num_turns) turns" else empty end),
      (if .duration_ms then
        "\(.duration_ms / 1000 * 10 | round / 10)s"
      else empty end),
      (if .total_cost_usd then
        "$\(.total_cost_usd * 10000 | round / 10000)"
      else empty end)
    ] | join(" | ")
  ')
  if [[ -n "$stats" ]]; then
    printf '%s  [%s]%s\n' "$_PCSJ_DIM" "$stats" "$_PCSJ_RST"
  fi
}

command_utils_pretty_claude_stream_json() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed." >&2
    exit 1
  fi

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue

    local type
    type=$(printf '%s' "$line" | jq -r '.type // ""' 2>/dev/null) || {
      printf '%s[raw] %s%s\n' "$_PCSJ_RED" "${line:0:120}" "$_PCSJ_RST"
      continue
    }

    case "$type" in
      system)    _pcsj_system "$line" ;;
      assistant) _pcsj_assistant "$line" ;;
      user)      _pcsj_user "$line" ;;
      result)    _pcsj_result "$line" ;;
      *)         printf '%s[%s] %s%s\n' "$_PCSJ_DIM" "$type" "${line:0:120}" "$_PCSJ_RST" ;;
    esac
  done
}
