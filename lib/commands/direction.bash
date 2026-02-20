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
