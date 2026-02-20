# aijigu (AI Jig Utilities)

Automation framework powered by Claude CLI.

## Requirements

- Bash
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code)
- `jq`

## Setup

Set `AIJIGU_DIRECTION_DIR` to the path where direction files are stored.

Set `AIJIGU_SLACK_INCOMMING_WEBHOOK_URL` to enable Slack notifications (optional).

## Commands

- `aijigu run <prompt>` - Run a prompt via `claude -p`.
- `aijigu notify slack <message>` - Send a message to Slack via incoming webhook.
- `aijigu utils pretty_claude_stream_json` - Format Claude's stream-json output.

### `aijigu direction`

Manage and execute direction files — task definitions that Claude works through autonomously.

- `aijigu direction init` - Initialize the direction directory.
- `aijigu direction add [-f <file> | -m <text>]` - Create a new direction from a file or text.
- `aijigu direction next` - Show the ID of the next direction to work on.
- `aijigu direction run <id>` - Execute a direction by ID.
- `aijigu direction auto` - Continuously execute directions in sequence.
- `aijigu direction continue <json>` - Decide whether to continue the auto loop.

## Caution

This is an experimental project with no guarantee of correct behavior. Commands run autonomously without user approval. AI-driven execution may cause serious security issues or damage.
