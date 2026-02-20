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
3. Generate a short, lowercase, hyphen-separated title from the task content in the same language as the input (e.g. 'setup-database' for English, 'データベース構築' for Japanese).
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

  source "$AIJIGU_ROOT/lib/commands/run.bash"
  command_run "$prompt" "$@"
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

command_direction_auto() {
  if [[ -z "${AIJIGU_DIRECTION_DIR:-}" ]]; then
    echo "Error: AIJIGU_DIRECTION_DIR is not set." >&2
    exit 1
  fi

  local aijigu="$AIJIGU_ROOT/bin/aijigu"

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
    set +e
    "$aijigu" direction run "$next_id"
    local run_exit=$?
    set -e

    if [[ $run_exit -ne 0 ]]; then
      echo "--- Direction #${next_id} exited with code ${run_exit}"
    else
      echo "--- Direction #${next_id} completed"
    fi

    # Check if completed (file moved to completed/)
    local completed="false"
    if [[ -f "$AIJIGU_DIRECTION_DIR/completed/$(basename "${direction_file:-}")" ]]; then
      completed="true"
    fi

    # Build JSON with direction execution info
    local result_json
    result_json=$(printf '{"id":%s,"name":"%s","exit_code":%s,"completed":%s}' \
      "$next_id" "$direction_name" "$run_exit" "$completed")

    echo "--- Checking whether to continue..."
    set +e
    "$aijigu" direction continue "$result_json"
    local continue_exit=$?
    set -e

    if [[ $continue_exit -ne 0 ]]; then
      echo "--- Auto loop stopped based on direction result"
      break
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
  result="$(CLAUDECODE= claude -p "あなたはaijigu direction autoループの継続判定を行うエージェントです。
直近実行されたdirectionの情報がJSON形式で与えられます。内容を読み取り、autoループを継続すべきかどうかを判断してください。

判断基準:
- directionが正常に完了し、次のdirectionを続行しても問題ない場合は継続
- 致命的なエラーが発生し、人間の介入が必要な場合は停止
- セキュリティ上の問題や破壊的な操作の失敗があった場合は停止
- 軽微なエラーや警告のみで作業自体は完了している場合は継続

JSON:
$json

回答は必ず「CONTINUE」または「STOP」の一単語のみを出力してください。判断理由は出力しないでください。" \
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
