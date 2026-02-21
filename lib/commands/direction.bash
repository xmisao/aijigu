#!/usr/bin/env bash

command_direction() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu direction <subcommand>" >&2
    exit 1
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
    _init)
      command_direction_init "$@"
      ;;
    add)
      command_direction_add "$@"
      ;;
    run)
      command_direction_run "$@"
      ;;
    _next)
      command_direction_next "$@"
      ;;
    auto)
      command_direction_auto "$@"
      ;;
    _continue)
      command_direction_continue "$@"
      ;;
    _last_message)
      command_direction_last_message "$@"
      ;;
    list)
      command_direction_list "$@"
      ;;
    *)
      echo "aijigu direction: unknown subcommand '${subcommand}'" >&2
      exit 1
      ;;
  esac
}

command_direction_init() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  if [[ -d "$AIJIGU_DIRECTION_DIR" ]]; then
    # Directory exists - check if it's empty
    if [[ -n "$(ls -A "$AIJIGU_DIRECTION_DIR" 2>/dev/null)" ]]; then
      echo "Error: $AIJIGU_DIRECTION_DIR already exists and is not empty." >&2
      exit 1
    fi
  fi

  mkdir -p "$AIJIGU_DIRECTION_DIR/completed"

  cat > "$AIJIGU_DIRECTION_DIR/README.md" <<'EOF'
# Aijigu Direction Directory

This directory stores direction files for aijigu.

## Format

Direction files are named in the format `<id>-<title>.md` (e.g., `1-setup-database.md`).

## Completed Directions

Once a direction has been completed, it should be moved to the `completed/` subdirectory
(e.g., `completed/1-setup-database.md`).
EOF

  echo "Initialized direction directory: $AIJIGU_DIRECTION_DIR"
}

command_direction_add() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local file="" message=""
  OPTIND=1
  while getopts "f:m:" opt; do
    case "$opt" in
      f) file="$OPTARG" ;;
      m) message="$OPTARG" ;;
      *) echo "Usage: aijigu direction add [-f <file> | -m <text>]" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$file" && -z "$message" ]]; then
    echo "Usage: aijigu direction add [-f <file> | -m <text>]" >&2
    exit 1
  fi

  # Build the content source part of the prompt
  local content_instruction
  if [[ -n "$file" ]]; then
    if [[ ! -f "$file" ]]; then
      echo "Error: File not found: $file" >&2
      exit 1
    fi
    file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    content_instruction="1. Read the task content from $file."
  else
    content_instruction="1. The task content is:
$message"
  fi

  local prompt_template
  prompt_template="$(aijigu_resolve_prompt AIJIGU_PROMPT_DIRECTION_ADD "$DEFAULT_PROMPT_DIRECTION_ADD")"
  local prompt
  prompt="$(aijigu_apply_placeholders "$prompt_template" \
    DIRECTION_DIR "$AIJIGU_DIRECTION_DIR" \
    CONTENT_INSTRUCTION "$content_instruction")"

  set +e
  CLAUDECODE= claude -p "$prompt" \
    --allowedTools "Bash,Read,Write" --output-format text --dangerously-skip-permissions
  local claude_exit=$?
  set -e

  exit "$claude_exit"
}

command_direction_run() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu direction run <id>" >&2
    exit 1
  fi

  local id="$1"
  shift

  # Find direction file matching the ID prefix
  local match
  match="$(ls "$AIJIGU_DIRECTION_DIR"/${id}-*.md 2>/dev/null | head -1 || true)"
  if [[ -z "$match" ]]; then
    echo "Error: No direction found with ID: $id" >&2
    exit 1
  fi

  local direction_name
  direction_name="$(basename "$match" .md)"

  local aijigu="$AIJIGU_ROOT/bin/aijigu"

  # Slack notification: started
  if [[ -n "${AIJIGU_SLACK_INCOMMING_WEBHOOK_URL:-}" ]]; then
    "$aijigu" _notify slack "[aijigu] Direction #${id} (${direction_name}) started" 2>/dev/null || true
  fi

  local max_retries="${AIJIGU_DIRECTION_INTERNAL_RETRY:-}"
  local attempt=0
  local run_exit=0
  local last_message_dir="$AIJIGU_DIRECTION_DIR/.last_messages"
  mkdir -p "$last_message_dir"
  local -a attempt_summaries=()

  while true; do
    attempt=$((attempt + 1))

    # --- Step 1: Execute the direction ---
    local prompt_template
    prompt_template="$(aijigu_resolve_prompt AIJIGU_PROMPT_DIRECTION_RUN "$DEFAULT_PROMPT_DIRECTION_RUN")"
    local prompt
    prompt="$(aijigu_apply_placeholders "$prompt_template" \
      ID "$id" \
      DIRECTION_FILE "$match" \
      COMPLETED_DIR "${AIJIGU_DIRECTION_DIR}/completed")"

    if [[ $attempt -gt 1 ]]; then
      local retry_template
      retry_template="$(aijigu_resolve_prompt AIJIGU_PROMPT_DIRECTION_RUN_RETRY "$DEFAULT_PROMPT_DIRECTION_RUN_RETRY")"
      local retry_prompt
      retry_prompt="$(aijigu_apply_placeholders "$retry_template" \
        ATTEMPT "$attempt")"
      prompt+="

${retry_prompt}"
    fi

    local tmp_stream
    tmp_stream="$(mktemp)"

    set +e
    CLAUDECODE= claude -p "$prompt" --output-format stream-json --verbose --dangerously-skip-permissions "$@" | tee "$tmp_stream"
    run_exit=${PIPESTATUS[0]}
    set -e

    # Extract and save last message from stream-json result event
    local result_text
    result_text="$(jq -r 'select(.type == "result") | .result // ""' "$tmp_stream" 2>/dev/null | tail -1 || true)"
    if [[ -n "$result_text" ]]; then
      printf '%s\n' "$result_text" > "$last_message_dir/${id}.txt"
    fi
    rm -f "$tmp_stream"

    # --- Step 2: Judge completion ---

    # 2a. Check if direction file was moved to completed/
    if [[ -f "$AIJIGU_DIRECTION_DIR/completed/$(basename "$match")" ]]; then
      break
    fi

    # 2b. Check hard retry limit from AIJIGU_DIRECTION_INTERNAL_RETRY
    if [[ -n "$max_retries" ]] && [[ $attempt -ge $max_retries ]]; then
      echo "--- Retry limit (${max_retries}) reached for direction #${id}" >&2
      break
    fi

    # 2c. Track attempt summaries and ask Claude to judge retry vs stop
    local summary="${result_text:0:200}"
    attempt_summaries+=("$summary")

    local history=""
    for i in "${!attempt_summaries[@]}"; do
      history+="Attempt $((i+1)): ${attempt_summaries[$i]}
"
    done

    local judge_template
    judge_template="$(aijigu_resolve_prompt AIJIGU_PROMPT_DIRECTION_RUN_JUDGE "$DEFAULT_PROMPT_DIRECTION_RUN_JUDGE")"
    local judge_prompt
    judge_prompt="$(aijigu_apply_placeholders "$judge_template" \
      ID "$id" \
      ATTEMPT "$attempt" \
      HISTORY "$history")"

    local judge_result
    set +e
    judge_result="$(CLAUDECODE= claude -p "$judge_prompt" \
      --output-format text --dangerously-skip-permissions 2>/dev/null)"
    set -e

    local answer
    answer="$(echo "$judge_result" | grep -oE '(RETRY|DONE)' | head -1)"

    if [[ "$answer" != "RETRY" ]]; then
      echo "--- Direction #${id}: stopping after attempt ${attempt} (judged as not making progress)" >&2
      break
    fi

    echo "--- Direction #${id}: retrying (attempt $((attempt + 1)))..." >&2
  done

  # Slack notification: finished (include last_message if available)
  if [[ -n "${AIJIGU_SLACK_INCOMMING_WEBHOOK_URL:-}" ]]; then
    local last_msg=""
    local last_msg_file="$last_message_dir/${id}.txt"
    if [[ -f "$last_msg_file" ]]; then
      last_msg="$(cat "$last_msg_file")"
    fi

    local slack_msg
    if [[ $run_exit -ne 0 ]]; then
      slack_msg="[aijigu] Direction #${id} (${direction_name}) finished (exit code: ${run_exit})"
    else
      slack_msg="[aijigu] Direction #${id} (${direction_name}) completed"
    fi

    if [[ -n "$last_msg" ]]; then
      slack_msg="${slack_msg}
\`\`\`
${last_msg}
\`\`\`"
    fi

    "$aijigu" _notify slack "$slack_msg" 2>/dev/null || true
  fi

  exit "$run_exit"
}

command_direction_next() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local prompt_template
  prompt_template="$(aijigu_resolve_prompt AIJIGU_PROMPT_DIRECTION_NEXT "$DEFAULT_PROMPT_DIRECTION_NEXT")"
  local prompt
  prompt="$(aijigu_apply_placeholders "$prompt_template" \
    DIRECTION_DIR "$AIJIGU_DIRECTION_DIR")"

  local result
  set +e
  result="$(CLAUDECODE= claude -p "$prompt" \
    --allowedTools "Bash,Read" --output-format text --dangerously-skip-permissions 2>/dev/null)"
  local claude_exit=$?
  set -e

  if [[ $claude_exit -ne 0 ]]; then
    exit "$claude_exit"
  fi

  # Extract numeric ID from output, ignore non-numeric responses
  local id
  id="$(echo "$result" | grep -oE '^[0-9]+$' | head -1)"
  if [[ -z "$id" ]]; then
    exit 1
  fi

  echo "$id"
}

command_direction_last_message() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local last_message_dir="$AIJIGU_DIRECTION_DIR/.last_messages"

  if [[ $# -eq 0 ]]; then
    # No ID specified: show the most recently modified last_message file
    if [[ ! -d "$last_message_dir" ]]; then
      echo "No last messages found." >&2
      exit 1
    fi
    local latest
    latest="$(ls -t "$last_message_dir"/*.txt 2>/dev/null | head -1 || true)"
    if [[ -z "$latest" ]]; then
      echo "No last messages found." >&2
      exit 1
    fi
    cat "$latest"
  else
    local id="$1"
    local msg_file="$last_message_dir/${id}.txt"
    if [[ ! -f "$msg_file" ]]; then
      echo "No last message found for direction #${id}." >&2
      exit 1
    fi
    cat "$msg_file"
  fi
}

command_direction_list() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local show_completed=false
  OPTIND=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --completed)
        show_completed=true
        shift
        ;;
      *)
        echo "Usage: aijigu direction list [--completed]" >&2
        exit 1
        ;;
    esac
  done

  local search_dir
  if [[ "$show_completed" == "true" ]]; then
    search_dir="$AIJIGU_DIRECTION_DIR/completed"
  else
    search_dir="$AIJIGU_DIRECTION_DIR"
  fi

  if [[ ! -d "$search_dir" ]]; then
    exit 0
  fi

  ls "$search_dir"/[0-9]*-*.md 2>/dev/null || true
}

command_direction_auto() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local aijigu="$AIJIGU_ROOT/bin/aijigu"
  local -a recent_ids=()

  while true; do
    echo "--- Checking for next direction..."
    local next_id
    next_id="$("$aijigu" direction _next)" || true

    if [[ -z "$next_id" ]]; then
      echo "--- No pending directions. Polling ${AIJIGU_DIRECTION_DIR} for new files (Ctrl+C to quit)..."
      while true; do
        sleep 2
        if ls "$AIJIGU_DIRECTION_DIR"/[0-9]*-*.md &>/dev/null; then
          echo "--- New direction file detected"
          break
        fi
      done
      continue
    fi

    # Find direction file name for JSON context
    local direction_file
    direction_file="$(ls "$AIJIGU_DIRECTION_DIR"/${next_id}-*.md 2>/dev/null | head -1 || true)"
    local direction_name
    direction_name="$(basename "${direction_file:-unknown}" .md)"

    echo "--- Starting direction #${next_id}"

    set +e
    "$aijigu" direction run "$next_id" | "$aijigu" _utils pretty_claude_stream_json
    local run_exit=${PIPESTATUS[0]}
    set -e

    if [[ $run_exit -ne 0 ]]; then
      echo "--- Direction #${next_id} exited with code ${run_exit}"
    else
      echo "--- Direction #${next_id} completed"
    fi

    # Track execution history (keep last 10)
    recent_ids+=("$next_id")
    if [[ ${#recent_ids[@]} -gt 10 ]]; then
      recent_ids=("${recent_ids[@]:1}")
    fi

    # Build history JSON array
    local history_json
    history_json="[$(IFS=,; echo "${recent_ids[*]}")]"

    # Check if completed (file moved to completed/)
    local completed="false"
    if [[ -f "$AIJIGU_DIRECTION_DIR/completed/$(basename "${direction_file:-}")" ]]; then
      completed="true"
    fi

    # Build JSON with direction execution info and history
    local result_json
    result_json=$(printf '{"id":%s,"name":"%s","exit_code":%s,"completed":%s,"history":%s}' \
      "$next_id" "$direction_name" "$run_exit" "$completed" "$history_json")

    echo "--- Checking whether to continue..."
    set +e
    "$aijigu" direction _continue "$result_json"
    local continue_exit=$?
    set -e

    if [[ $continue_exit -ne 0 ]]; then
      echo "--- Auto loop paused based on direction result. Switching to polling..."
      while true; do
        sleep 2
        if ls "$AIJIGU_DIRECTION_DIR"/[0-9]*-*.md &>/dev/null; then
          echo "--- New direction file detected"
          break
        fi
      done
    fi
  done
}

command_direction_continue() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu direction _continue <json>" >&2
    exit 1
  fi

  local json="$1"

  local prompt_template
  prompt_template="$(aijigu_resolve_prompt AIJIGU_PROMPT_DIRECTION_CONTINUE "$DEFAULT_PROMPT_DIRECTION_CONTINUE")"
  local prompt
  prompt="$(aijigu_apply_placeholders "$prompt_template" \
    JSON "$json")"

  local result
  set +e
  result="$(CLAUDECODE= claude -p "$prompt" \
    --output-format text --dangerously-skip-permissions 2>/dev/null)"
  local claude_exit=$?
  set -e

  if [[ $claude_exit -ne 0 ]]; then
    exit "$claude_exit"
  fi

  local answer
  answer="$(echo "$result" | grep -oE '(CONTINUE|STOP)' | head -1)"

  if [[ "$answer" == "CONTINUE" ]]; then
    exit 0
  else
    exit 1
  fi
}
