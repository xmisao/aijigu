#!/usr/bin/env bash

command_web() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: aijigu web <subcommand>" >&2
    echo "" >&2
    echo "Subcommands:" >&2
    echo "  start [-p PORT] [-b HOST]   Start the web server" >&2
    exit 1
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
    start)
      command_web_start "$@"
      ;;
    *)
      echo "aijigu web: unknown subcommand '${subcommand}'" >&2
      exit 1
      ;;
  esac
}

command_web_start() {
  exec ruby "$AIJIGU_ROOT/lib/web/server.rb" "$@"
}
