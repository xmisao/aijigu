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

  local file=""
  OPTIND=1
  while getopts "f:" opt; do
    case "$opt" in
      f) file="$OPTARG" ;;
      *) echo "Usage: aijigu direction add -f <file>" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$file" ]]; then
    echo "Usage: aijigu direction add -f <file>" >&2
    exit 1
  fi

  if [[ ! -f "$file" ]]; then
    echo "Error: File not found: $file" >&2
    exit 1
  fi

  # Resolve to absolute path for claude
  file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

  set +e
  CLAUDECODE= claude -p "Create a new direction file in $AIJIGU_DIRECTION_DIR.

Steps:
1. Read the task content from $file.
2. List existing .md files in $AIJIGU_DIRECTION_DIR and $AIJIGU_DIRECTION_DIR/completed to find the highest numeric ID prefix. The next ID is max + 1, starting from 1 if none exist. Do not zero-pad the ID.
3. Generate a short, lowercase, hyphen-separated title from the task content in the same language as the input (e.g. 'setup-database' for English, 'データベース構築' for Japanese).
4. Write the task content to $AIJIGU_DIRECTION_DIR/<id>-<title>.md.
5. Output only the created filename (e.g. '1-setup-database.md') to confirm." \
    --allowedTools "Bash,Read,Write" --output-format text --dangerously-skip-permissions
  local claude_exit=$?
  set -e

  exit "$claude_exit"
}
