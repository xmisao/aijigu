# aijigu (AI Jig Utilities)

Automation framework powered by Claude CLI.

## Requirements

- Bash
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code)
- `jq`
- Ruby (for `aijigu web`)

## Setup

Set `AIJIGU_DIRECTION_DIR` to the path where direction files are stored.

Set `AIJIGU_SLACK_INCOMMING_WEBHOOK_URL` to enable Slack notifications (optional).

Set `AIJIGU_WEB_USERNAME` and `AIJIGU_WEB_PASSWORD` to enable web authentication (optional).

## Commands

### `aijigu direction`

Manage and execute direction files — task definitions that Claude works through autonomously.

- `aijigu direction init` - Initialize the direction directory.
- `aijigu direction add [-f <file> | -m <text>]` - Create a new direction from a file or text.
- `aijigu direction list [--completed]` - List pending or completed directions.
- `aijigu direction show <id>` - Display a direction's content.
- `aijigu direction run <id>` - Execute a direction by ID.
- `aijigu direction auto` - Continuously execute directions in sequence.

### `aijigu web`

Web UI for browsing and submitting directions.

- `aijigu web start [-p PORT] [-b HOST]` - Start the web server (default: `127.0.0.1:8080`).

### Internal commands (internal API)

Internal commands are prefixed with `_` and are not intended for direct use. These are internal APIs used by other commands.

- `aijigu _run <prompt>` - Run a prompt via `claude -p`.
- `aijigu _notify slack <message>` - Send a message to Slack via incoming webhook.
- `aijigu _utils pretty_claude_stream_json` - Format Claude's stream-json output.
- `aijigu direction _next` - Show the ID of the next direction to work on.
- `aijigu direction _continue <json>` - Decide whether to continue the auto loop.
- `aijigu direction _last_message [id]` - Show the last message from a direction execution.

## Caution

This is an experimental project with no guarantee of correct behavior. Commands run autonomously without user approval. AI-driven execution may cause serious security issues or damage.
