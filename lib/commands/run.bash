#!/usr/bin/env bash

command_run() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu run <prompt>" >&2
    exit 1
  fi

  local prompt="$1"
  shift

  set +e
  CLAUDECODE= claude -p "$prompt" --output-format stream-json --verbose "$@"
  local claude_exit=$?
  set -e

  exit "$claude_exit"
}
