# aijigu

Automation framework powered by Claude CLI.

## Requirements

- Bash
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-code)

## Setup

Set `AIJIGU_DIRECTION_DIR` to the path where direction files are stored.

## Commands

- `aijigu run <prompt>` - Run a prompt via `claude -p`.
- `aijigu direction init` - Initialize the direction directory.
- `aijigu direction add -f <file>` - Create a new direction from a file.
- `aijigu direction next` - Show the ID of the next direction to work on.
- `aijigu direction run <id>` - Execute a direction by ID.
- `aijigu direction auto` - Continuously execute directions in sequence.

## Caution

This is an experimental project with no guarantee of correct behavior. Commands run autonomously without user approval. AI-driven execution may cause serious security issues or damage.
