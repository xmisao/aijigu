#!/usr/bin/env bash

command_direction() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu direction <subcommand>" >&2
    exit 1
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
    init)
      command_direction_init "$@"
      ;;
    add)
      command_direction_add "$@"
      ;;
    run)
      command_direction_run "$@"
      ;;
    next)
      command_direction_next "$@"
      ;;
    auto)
      command_direction_auto "$@"
      ;;
    continue)
      command_direction_continue "$@"
      ;;
    last_message)
      command_direction_last_message "$@"
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

  set +e
  CLAUDECODE= claude -p "Create a new direction file in $AIJIGU_DIRECTION_DIR.

Steps:
$content_instruction
2. List existing .md files in $AIJIGU_DIRECTION_DIR and $AIJIGU_DIRECTION_DIR/completed to find the highest numeric ID prefix. The next ID is max + 1, starting from 1 if none exist. Do not zero-pad the ID.
3. Generate a short, lowercase, hyphen-separated title from the task content in the same language as the input (e.g. 'setup-database'). Non-ASCII characters are allowed in the title.
4. Write the task content to $AIJIGU_DIRECTION_DIR/<id>-<title>.md.
5. Output only the created filename (e.g. '1-setup-database.md') to confirm." \
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

  local prompt
  prompt="Complete the direction #${id}.

The direction file is located at: ${match}
The completed directory is: ${AIJIGU_DIRECTION_DIR}/completed

Follow these steps. All output must be in the same language as the direction.

1. Read and understand direction #${id}.
2. Carry out the work as directed.
3. Append work notes to the direction file.
4. If the work is fully completed, move the direction file to the completed directory.
5. If the work is within a Git-managed area and fully completed, commit the changes.

If you cannot complete the work, still follow the same steps to record what was done.
Never use Plan mode.
The user will not provide any additional instructions or approvals. Work autonomously."

  # Run claude, capturing stream-json output to extract last message
  local tmp_stream
  tmp_stream="$(mktemp)"

  set +e
  CLAUDECODE= claude -p "$prompt" --output-format stream-json --verbose --dangerously-skip-permissions "$@" | tee "$tmp_stream"
  local run_exit=${PIPESTATUS[0]}
  set -e

  # Extract and save last message from stream-json result event
  local last_message_dir="$AIJIGU_DIRECTION_DIR/.last_messages"
  mkdir -p "$last_message_dir"
  local result_text
  result_text="$(jq -r 'select(.type == "result") | .result // ""' "$tmp_stream" 2>/dev/null | tail -1 || true)"
  if [[ -n "$result_text" ]]; then
    printf '%s\n' "$result_text" > "$last_message_dir/${id}.txt"
  fi

  rm -f "$tmp_stream"
  exit "$run_exit"
}

command_direction_next() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local result
  set +e
  result="$(CLAUDECODE= claude -p "Look at the direction files in $AIJIGU_DIRECTION_DIR (not in the completed/ subdirectory).
Read their contents and determine which direction should be worked on next, considering priority and dependencies.
Output only the numeric ID of the chosen direction, nothing else.
If there are no pending directions, output nothing." \
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
    next_id="$("$aijigu" direction next)" || true

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

    # Slack notification: started
    if [[ -n "${AIJIGU_SLACK_INCOMMING_WEBHOOK_URL:-}" ]]; then
      "$aijigu" notify slack "[aijigu auto] Direction #${next_id} (${direction_name}) started" 2>/dev/null || true
    fi

    set +e
    "$aijigu" direction run "$next_id" | "$aijigu" utils pretty_claude_stream_json
    local run_exit=${PIPESTATUS[0]}
    set -e

    if [[ $run_exit -ne 0 ]]; then
      echo "--- Direction #${next_id} exited with code ${run_exit}"
    else
      echo "--- Direction #${next_id} completed"
    fi

    # Slack notification: finished (include last_message if available)
    if [[ -n "${AIJIGU_SLACK_INCOMMING_WEBHOOK_URL:-}" ]]; then
      local last_msg=""
      local last_msg_file="$AIJIGU_DIRECTION_DIR/.last_messages/${next_id}.txt"
      if [[ -f "$last_msg_file" ]]; then
        last_msg="$(cat "$last_msg_file")"
      fi

      local slack_msg
      if [[ $run_exit -ne 0 ]]; then
        slack_msg="[aijigu auto] Direction #${next_id} (${direction_name}) finished (exit code: ${run_exit})"
      else
        slack_msg="[aijigu auto] Direction #${next_id} (${direction_name}) completed"
      fi

      if [[ -n "$last_msg" ]]; then
        slack_msg="${slack_msg}
\`\`\`
${last_msg}
\`\`\`"
      fi

      "$aijigu" notify slack "$slack_msg" 2>/dev/null || true
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
    "$aijigu" direction continue "$result_json"
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
    echo "Usage: aijigu direction continue <json>" >&2
    exit 1
  fi

  local json="$1"

  local result
  set +e
  result="$(CLAUDECODE= claude -p "You are an agent that decides whether the aijigu direction auto-loop should continue.

You will receive information about the most recently executed direction in JSON format. Read it and decide whether the auto-loop should continue or stop.

The JSON contains a 'history' field: an array of up to the last 10 executed direction IDs. If the same ID appears repeatedly, a stuck loop is likely and you should stop.

Decision criteria:
- CONTINUE if the direction completed successfully and proceeding to the next one is safe.
- STOP if a fatal error occurred and human intervention is needed.
- STOP if there was a security issue or a destructive operation failed.
- CONTINUE if only minor errors or warnings occurred but the work itself was completed.
- STOP if the same direction ID appears repeatedly in the history.

JSON:
$json

You must respond with exactly one word: either CONTINUE or STOP. Do not output any reasoning." \
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
