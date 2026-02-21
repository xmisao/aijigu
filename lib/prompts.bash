#!/usr/bin/env bash

# Default prompt definitions for aijigu.
# Each prompt can be overridden by setting the corresponding environment variable.

# --- AIJIGU_PROMPT_DIRECTION_ADD ---
# Prompt for creating a new direction file from user input.
# Available placeholders: {{DIRECTION_DIR}}, {{CONTENT_INSTRUCTION}}
DEFAULT_PROMPT_DIRECTION_ADD='Create a new direction file in {{DIRECTION_DIR}}.

Steps:
{{CONTENT_INSTRUCTION}}
2. List existing .md files in {{DIRECTION_DIR}} and {{DIRECTION_DIR}}/completed to find the highest numeric ID prefix. The next ID is max + 1, starting from 1 if none exist. Do not zero-pad the ID.
3. Generate a short, lowercase, hyphen-separated title from the task content in the same language as the input (e.g. '"'"'setup-database'"'"'). Non-ASCII characters are allowed in the title.
4. Write the task content to {{DIRECTION_DIR}}/<id>-<title>.md.
5. Output only the created filename (e.g. '"'"'1-setup-database.md'"'"') to confirm.'

# --- AIJIGU_PROMPT_DIRECTION_RUN ---
# Prompt for executing a direction.
# Available placeholders: {{ID}}, {{DIRECTION_FILE}}, {{COMPLETED_DIR}}
DEFAULT_PROMPT_DIRECTION_RUN='Complete the direction #{{ID}}.

The direction file is located at: {{DIRECTION_FILE}}
The completed directory is: {{COMPLETED_DIR}}

Follow these steps. All output must be in the same language as the direction.

1. Read and understand direction #{{ID}}.
2. Carry out the work as directed.
3. Append work notes to the direction file.
4. If the work is fully completed, move the direction file to the completed directory.
5. If the work is within a Git-managed area and fully completed, commit the changes.

If you cannot complete the work, still follow the same steps to record what was done.
Never use Plan mode.
The user will not provide any additional instructions or approvals. Work autonomously.'

# --- AIJIGU_PROMPT_DIRECTION_RUN_RETRY ---
# Prompt appended on retry attempts.
# Available placeholders: {{ATTEMPT}}
DEFAULT_PROMPT_DIRECTION_RUN_RETRY='This is retry attempt #{{ATTEMPT}}. The direction file may contain work notes from previous attempts. Review them and continue from where the previous attempt left off.'

# --- AIJIGU_PROMPT_DIRECTION_RUN_JUDGE ---
# Prompt for judging whether a direction execution should be retried.
# Available placeholders: {{ID}}, {{ATTEMPT}}, {{HISTORY}}
DEFAULT_PROMPT_DIRECTION_RUN_JUDGE='You are judging whether a direction execution should be retried.

Direction #{{ID}} was executed {{ATTEMPT}} time(s) but the direction file was NOT moved to the completed directory, meaning the work may not be fully done.

Execution history (last message summaries):
{{HISTORY}}
Decision rules:
- RETRY if the execution made progress and more work remains.
- DONE if the execution seems stuck in an infinite loop (similar messages repeating across attempts without meaningful progress).
- DONE if a fatal or unrecoverable error occurred that retrying will not fix.
- DONE if attempt count is already high (currently {{ATTEMPT}}) without clear progress.

Respond with exactly one word: RETRY or DONE.'

# --- AIJIGU_PROMPT_DIRECTION_NEXT ---
# Prompt for selecting the next direction to work on.
# Available placeholders: {{DIRECTION_DIR}}
DEFAULT_PROMPT_DIRECTION_NEXT='Look at the direction files in {{DIRECTION_DIR}} (not in the completed/ subdirectory).
Read their contents and determine which direction should be worked on next, considering priority and dependencies.
Output only the numeric ID of the chosen direction, nothing else.
If there are no pending directions, output nothing.'

# --- AIJIGU_PROMPT_DIRECTION_CONTINUE ---
# Prompt for deciding whether the auto-loop should continue.
# Available placeholders: {{JSON}}
DEFAULT_PROMPT_DIRECTION_CONTINUE='You are an agent that decides whether the aijigu direction auto-loop should continue.

You will receive information about the most recently executed direction in JSON format. Read it and decide whether the auto-loop should continue or stop.

The JSON contains a '\''history'\'' field: an array of up to the last 10 executed direction IDs. If the same ID appears repeatedly, a stuck loop is likely and you should stop.

Decision criteria:
- CONTINUE if the direction completed successfully and proceeding to the next one is safe.
- STOP if a fatal error occurred and human intervention is needed.
- STOP if there was a security issue or a destructive operation failed.
- CONTINUE if only minor errors or warnings occurred but the work itself was completed.
- STOP if the same direction ID appears repeatedly in the history.

JSON:
{{JSON}}

You must respond with exactly one word: either CONTINUE or STOP. Do not output any reasoning.'

# Resolve a prompt: use the environment variable if set, otherwise use the default.
# Usage: aijigu_resolve_prompt <ENV_VAR_NAME> <DEFAULT_VALUE>
aijigu_resolve_prompt() {
  local env_var="$1"
  local default_value="$2"
  local value="${!env_var:-$default_value}"
  echo "$value"
}

# Apply placeholder substitutions to a prompt string.
# Usage: aijigu_apply_placeholders <prompt> <key1> <value1> [<key2> <value2> ...]
aijigu_apply_placeholders() {
  local prompt="$1"
  shift
  while [[ $# -ge 2 ]]; do
    local key="$1"
    local value="$2"
    prompt="${prompt//\{\{$key\}\}/$value}"
    shift 2
  done
  echo "$prompt"
}
