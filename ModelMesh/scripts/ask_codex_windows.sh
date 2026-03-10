#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_codex_windows.sh <task> [options]
  ask_codex_windows.sh -t <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -t, --task <text>            Alias for positional task (backward compat)
  (stdin)                      Pipe task text via stdin if no arg/flag given

File context (optional, repeatable):
  -f, --file <path>            Priority file path

Multi-turn:
      --session <id>           Resume a previous session (thread_id from prior run)

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <name>           Model override
      --reasoning <level>      Reasoning effort: low, medium, high (default: medium)
      --sandbox <mode>         Sandbox mode override
      --read-only              Read-only sandbox (no file changes)
      --full-auto              Full-auto mode (default)
  -o, --output <path>          Output file path
  -h, --help                   Show this help

Output (on success):
  session_id=<thread_id>       Use with --session for follow-up calls
  output_path=<file>           Path to response markdown

Examples:
  # New task (positional)
  ask_codex_windows.sh "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_codex_windows.sh "Fix the bug" -w /other/repo

  # Continue conversation
  ask_codex_windows.sh "Also add retry logic" --session <id>
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

ensure_codex() {
  if command -v codex >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] codex not found. Installing @openai/codex via npm..." >&2
  if ! command -v npm >/dev/null 2>&1; then
    echo "[ERROR] npm is required to install codex. Please install Node.js (https://nodejs.org) and retry." >&2
    exit 1
  fi
  if npm i -g @openai/codex >&2; then
    hash -r 2>/dev/null || true   # refresh PATH cache so codex is found immediately
    if command -v codex >/dev/null 2>&1; then
      echo "[INFO] codex installed successfully." >&2
    else
      echo "[ERROR] codex was installed but is still not in PATH." >&2
      echo "[ERROR] Add npm global bin to PATH. Find it with: npm bin -g" >&2
      echo "[ERROR] npm global bin: $(npm bin -g 2>/dev/null || echo 'unavailable')" >&2
      exit 1
    fi
  else
    echo "[ERROR] Failed to install @openai/codex. Try running manually: npm i -g @openai/codex" >&2
    exit 1
  fi
}

trim_whitespace() {
  awk 'BEGIN { RS=""; ORS="" } { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print }' <<<"$1"
}

to_abs_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local dir
    dir="$(cd "$(dirname "$target")" && pwd)"
    echo "$dir/$(basename "$target")"
    return
  fi
  echo "$target"
}

resolve_file_ref() {
  local workspace="$1" raw="$2" cleaned
  cleaned="$(trim_whitespace "$raw")"
  [[ -z "$cleaned" ]] && { echo ""; return; }
  if [[ "$cleaned" =~ ^(.+)#L[0-9]+$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" =~ ^(.+):[0-9]+(-[0-9]+)?$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi

  # Convert Windows paths to Unix-style for consistency
  if [[ "$cleaned" =~ ^[A-Za-z]: ]]; then
    cleaned="$(tr '\\' '/' <<< "$cleaned")"  # Convert backslashes to forward slashes
    cleaned="$(echo "$cleaned" | sed -E 's#^[A-Za-z]:##')"  # C:/path -> /path
    [[ "$cleaned" != /* ]] && cleaned="/$cleaned"
  fi

  # Handle absolute paths (Unix-style /path or Windows-style /path after conversion)
  if [[ "$cleaned" != /* ]] && ! [[ "$cleaned" =~ ^[A-Za-z]: ]]; then
    cleaned="$workspace/$cleaned"
  fi
  to_abs_if_exists "$cleaned"
}

append_file_refs() {
  local raw="$1" item
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    local trimmed
    trimmed="$(trim_whitespace "$item")"
    [[ -n "$trimmed" ]] && file_refs+=("$trimmed")
  done
}

# --- Parse arguments ---

workspace="${PWD}"
task_text=""
model=""
reasoning_effort=""
sandbox_mode=""
read_only=false
full_auto=true
output_path=""
session_id=""
file_refs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)   workspace="${2:-}"; shift 2 ;;
    -t|--task)        task_text="${2:-}"; shift 2 ;;
    -f|--file|--focus) append_file_refs "${2:-}"; shift 2 ;;
    --model)          model="${2:-}"; shift 2 ;;
    --reasoning)      reasoning_effort="${2:-}"; shift 2 ;;
    --sandbox)        sandbox_mode="${2:-}"; full_auto=false; shift 2 ;;
    --read-only)      read_only=true; full_auto=false; shift ;;
    --full-auto)      full_auto=true; shift ;;
    --session)        session_id="${2:-}"; shift 2 ;;
    -o|--output)      output_path="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                if [[ -z "$task_text" ]]; then task_text="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1; fi ;;
  esac
done

ensure_codex
require_cmd jq

# --- Validate inputs ---

if [[ ! -d "$workspace" ]]; then
  echo "[ERROR] Workspace does not exist: $workspace" >&2; exit 1
fi
workspace="$(cd "$workspace" && pwd)"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi
task_text="$(trim_whitespace "$task_text")"

if [[ -z "$task_text" ]]; then
  echo "[ERROR] Request text is empty. Pass a positional arg, --task, or stdin." >&2; exit 1
fi

# --- Prepare output path ---

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  output_path="$skill_dir/.runtime/${timestamp}.md"
fi
mkdir -p "$(dirname "$output_path")"

# --- Build file context block ---

file_block=""
if (( ${#file_refs[@]} > 0 )); then
  file_block=$'\nPriority files (read these first before making changes):'
  for ref in "${file_refs[@]}"; do
    resolved="$(resolve_file_ref "$workspace" "$ref")"
    [[ -z "$resolved" ]] && continue
    exists_tag="missing"
    [[ -e "$resolved" ]] && exists_tag="exists"
    file_block+=$'\n- '"${resolved} (${exists_tag})"
  done
fi

# --- Build prompt ---

prompt="$task_text"
if [[ -n "$file_block" ]]; then
  prompt+=$'\n'"$file_block"
fi

# --- Determine reasoning effort ---

if [[ -z "$reasoning_effort" ]]; then
  reasoning_effort="medium"
fi

# --- Build codex command ---

if [[ -n "$session_id" ]]; then
  # Resume mode: continue a previous session
  cmd=(codex exec resume --skip-git-repo-check --json -c "model_reasoning_effort=\"$reasoning_effort\"")
  if [[ "$read_only" == true ]]; then
    cmd+=(--sandbox read-only)
  elif [[ -n "$sandbox_mode" ]]; then
    cmd+=(--sandbox "$sandbox_mode")
  elif [[ "$full_auto" == true ]]; then
    cmd+=(--full-auto)
  fi
  [[ -n "$model" ]] && cmd+=(--model "$model")
  cmd+=("$session_id")
else
  # New session
  cmd=(codex exec --skip-git-repo-check --json -c "model_reasoning_effort=\"$reasoning_effort\"")
  if [[ "$read_only" == true ]]; then
    cmd+=(--sandbox read-only)
  elif [[ -n "$sandbox_mode" ]]; then
    cmd+=(--sandbox "$sandbox_mode")
  elif [[ "$full_auto" == true ]]; then
    cmd+=(--full-auto)
  fi
  [[ -n "$model" ]] && cmd+=(--model "$model")
fi

# --- Progress display helper ---

print_progress() {
  local json="$1"
  local type item_type name
  type="$(jq -r '.type // empty' <<<"$json" 2>/dev/null || true)"
  item_type="$(jq -r '.item.type // empty' <<<"$json" 2>/dev/null || true)"
  name="$(jq -r '.item.name // .item.command // empty' <<<"$json" 2>/dev/null || true)"

  if [[ "$type" == "item.started" ]]; then
    case "$item_type" in
      tool_call) echo "[→] Tool: $name" >&2 ;;
      command_execution) echo "[→] Shell: ${name:0:60}" >&2 ;;
    esac
  elif [[ "$type" == "item.completed" ]]; then
    case "$item_type" in
      tool_call) echo "[✓] Tool: $name" >&2 ;;
      command_execution) echo "[✓] Shell: ${name:0:60}" >&2 ;;
    esac
  fi
}

# --- Execute and capture JSON output (Windows compatible) ---

stderr_file="$(mktemp)"
json_file="$(mktemp)"
prompt_file="$(mktemp)"
trap 'rm -f "$stderr_file" "$json_file" "$prompt_file"' EXIT

# Write prompt to a temp file
printf "%s" "$prompt" > "$prompt_file"

# Run codex directly without script command (Git Bash provides TTY)
(cd "$workspace" && "${cmd[@]}" < "$prompt_file" 2>"$stderr_file") | while IFS= read -r line; do
  # Strip terminal artifacts
  cleaned="${line//$'\r'/}"
  cleaned="${cleaned//$'\004'/}"
  [[ -z "$cleaned" ]] && continue
  # Only process JSON lines
  [[ "$cleaned" != \{* ]] && continue
  # Write to json_file
  printf '%s\n' "$cleaned" >> "$json_file"
  # Print progress
  case "$cleaned" in
    *'"item.started"'*|*'"item.completed"'*) print_progress "$cleaned" ;;
  esac
done

# --- Check for errors ---

if [[ -s "$stderr_file" ]]; then
  echo "[STDERR from codex]:" >&2
  cat "$stderr_file" >&2
fi

if [[ ! -s "$json_file" ]]; then
  echo "[ERROR] No JSON output from codex. Check stderr above." >&2
  exit 1
fi

# --- Extract thread_id ---

thread_id="$(jq -r 'select(.type == "thread.started") | .thread_id' < "$json_file" 2>/dev/null | head -1)"

# --- Build markdown output ---

{
  echo "# CodeX Response"
  echo ""

  # Show shell commands
  jq -r '
    select(.type == "item.completed" and .item.type == "command_execution")
    | .item
    | "### Shell: `" + (.command // "unknown" | gsub("^/bin/zsh -lc "; "") | gsub("^/bin/bash -c "; ""))[0:200] + "`\n" + (.aggregated_output // "" | .[0:500])
  ' < "$json_file" 2>/dev/null

  # Show file operations
  jq -r '
    select(.type == "item.completed" and .item.type == "tool_call")
    | .item
    | if .name == "write_file" then
        "### File written: " + (.arguments | fromjson | .path // "unknown")
      elif .name == "patch_file" then
        "### File patched: " + (.arguments | fromjson | .path // "unknown")
      elif .name == "shell" then
        "### Shell: `" + (.arguments | fromjson | .command // "unknown")[0:200] + "`\n" + (.output // "" | .[0:500])
      else empty
      end
  ' < "$json_file" 2>/dev/null

  # Show agent messages
  jq -r '
    select(.type == "item.completed" and .item.type == "agent_message")
    | .item.text
  ' < "$json_file" 2>/dev/null
} > "$output_path"

# Fallback if nothing captured
if [[ ! -s "$output_path" ]]; then
  echo "(no response from codex)" > "$output_path"
fi

# --- Output results ---

if [[ -n "$thread_id" ]]; then
  echo "session_id=$thread_id"
fi
echo "output_path=$output_path"
