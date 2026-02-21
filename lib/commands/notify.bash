#!/usr/bin/env bash

command_notify() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu _notify <subcommand>" >&2
    echo "" >&2
    echo "Subcommands:" >&2
    echo "  slack <message>   Send a message to Slack via incoming webhook" >&2
    exit 1
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
    slack)
      command_notify_slack "$@"
      ;;
    *)
      echo "aijigu _notify: unknown subcommand '${subcommand}'" >&2
      exit 1
      ;;
  esac
}

command_notify_slack() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: aijigu _notify slack <message>" >&2
    exit 1
  fi

  if [[ -z "${AIJIGU_SLACK_INCOMMING_WEBHOOK_URL:-}" ]]; then
    echo "Error: AIJIGU_SLACK_INCOMMING_WEBHOOK_URL is not set" >&2
    exit 1
  fi

  local message="$1"

  # Truncate to 3800 chars to stay within Slack message limits
  if [[ "${#message}" -gt 3800 ]]; then
    message="${message:0:3800}...(truncated)"
  fi

  # JSON-escape the message safely using python3's json.dumps
  local escaped
  escaped=$(printf '%s' "$message" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

  curl -s -o /dev/null -X POST -H 'Content-type: application/json' \
    --data "{\"text\": ${escaped}}" \
    "$AIJIGU_SLACK_INCOMMING_WEBHOOK_URL" || true
}
