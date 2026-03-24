#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_gemini.sh [options] "<task text>"

The first non-flag argument is the task text (or use -t / --task, or pipe from stdin).

Options:
  -t, --task <text>            Request text (alternative to positional arg)
      --html                   Output as self-contained HTML (shorthand for --output-type html)
      --svg                    Output as SVG (shorthand for --output-type svg)
      --output-type <type>     Expected output: text (default), html, svg
  -o, --output <path>          Output file path (default: auto-generated)
                               Auto-infers output type from extension (.html, .svg)
  -h, --help                   Show this help

Output (on success):
  output_path=<file>           Path to response file

Examples:
  ask_gemini.sh "Design a landing page for a coffee shop" --html
  ask_gemini.sh "Create an SVG icon for a settings gear" --svg
  ask_gemini.sh "Give me 3 color palette suggestions for a tech blog"
  ask_gemini.sh "Design a pricing card" -o ./designs/card.html
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

# --- Windows compatibility ---
IS_WINDOWS=false
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=true ;;
esac

# Strip carriage returns from a string (Windows line endings)
strip_cr() {
  printf '%s' "$1" | tr -d '\r'
}

# --- Parse arguments ---

task_text=""
output_path=""
output_type="text"
output_type_explicit=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--task)        task_text="${2:-}"; shift 2 ;;
    -o|--output)      output_path="${2:-}"; shift 2 ;;
    --output-type)    output_type="${2:-}"; output_type_explicit=true; shift 2 ;;
    --html)           output_type="html"; output_type_explicit=true; shift ;;
    --svg)            output_type="svg"; output_type_explicit=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)
      if [[ -z "$task_text" ]]; then
        task_text="$1"; shift
      else
        echo "[ERROR] Unknown argument: $1" >&2; usage >&2; exit 1
      fi
      ;;
  esac
done

# Auto-infer output type from output path extension
if [[ "$output_type_explicit" == false && -n "$output_path" ]]; then
  case "$output_path" in
    *.html) output_type="html" ;;
    *.svg)  output_type="svg" ;;
  esac
fi

require_cmd curl
require_cmd jq

# --- Unified config resolution ---
# Reads from two sources: environment variables and ~/.config/gemini-designer/config.
# If both sources provide a value and they differ, the user is prompted to choose.
# Priority when only one source is present: whichever has a value wins.
# Non-interactive environments (no TTY): env var takes priority automatically.

CONFIG_FILE="$HOME/.config/gemini-designer/config"

# Read all values from config file (strip \r for Windows line endings)
_read_cfg() {
  [[ -f "$CONFIG_FILE" ]] && grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" | tr -d '\r' || echo ""
}
cfg_api_key="$(_read_cfg GEMINI_API_KEY)"
cfg_base_url="$(_read_cfg GOOGLE_GEMINI_BASE_URL)"
cfg_model="$(_read_cfg GEMINI_MODEL)"

# Helper: resolve a single config variable from env + config file.
# If both sources have different values, prompt the user to choose.
choose_value() {
  local label="$1" env_val="$2" cfg_val="$3"
  # Strip surrounding whitespace
  env_val="$(echo "$env_val" | tr -d '[:space:]')" 2>/dev/null || true
  cfg_val="$(echo "$cfg_val" | tr -d '[:space:]')" 2>/dev/null || true

  if [[ -n "$env_val" && -n "$cfg_val" && "$env_val" != "$cfg_val" ]]; then
    # Both present and different — ask the user if a TTY is available
    if tty >/dev/null 2>&1; then
      echo "[CONFIG] $label found in two sources with different values:" >&2
      echo "  1) env var : $env_val" >&2
      echo "  2) config  : $cfg_val ($CONFIG_FILE)" >&2
      local choice
      while true; do
        printf "Which should be used? [1/2]: " >&2
        read -r choice </dev/tty
        case "$choice" in
          1) echo "$env_val"; return ;;
          2) echo "$cfg_val"; return ;;
          *) echo "  Please enter 1 or 2." >&2 ;;
        esac
      done
    else
      echo "[INFO] $label: both env and config have values; using env var (non-interactive)." >&2
      echo "$env_val"
    fi
  elif [[ -n "$env_val" ]]; then
    echo "$env_val"
  elif [[ -n "$cfg_val" ]]; then
    echo "$cfg_val"
  else
    echo ""
  fi
}

# Resolve GEMINI_API_KEY
env_api_key="${GEMINI_API_KEY:-${ZENMUX_API_KEY:-}}"
api_key="$(choose_value "GEMINI_API_KEY" "$env_api_key" "$cfg_api_key")"

# .env.local fallback (project-level, checked if still empty)
if [[ -z "$api_key" ]]; then
  for candidate in ".env.local" "../.env.local" "../../.env.local"; do
    if [[ -f "$candidate" ]]; then
      found="$(grep -E '^GEMINI_API_KEY=' "$candidate" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
      if [[ -z "$found" ]]; then
        found="$(grep -E '^ZENMUX_API_KEY=' "$candidate" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r')"
      fi
      found="${found//\'/}"
      found="${found//\"/}"
      if [[ -n "$found" ]]; then
        api_key="$found"
        break
      fi
    fi
  done
fi

# Legacy api_key file fallback
if [[ -z "$api_key" && -f "$HOME/.config/gemini-designer/api_key" ]]; then
  api_key="$(cat "$HOME/.config/gemini-designer/api_key" | tr -d '[:space:]')"
fi

# ~/.gemini/.env fallback
if [[ -z "$api_key" && -f "$HOME/.gemini/.env" ]]; then
  _gemini_env="$HOME/.gemini/.env"
  _found_key="$(grep -E '^GEMINI_API_KEY=' "$_gemini_env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]\r')"
  if [[ -n "$_found_key" ]]; then
    api_key="$_found_key"
    # Also load BASE_URL and MODEL from this file if not already set
    if [[ -z "${GOOGLE_GEMINI_BASE_URL:-}" && -z "$cfg_base_url" ]]; then
      cfg_base_url="$(grep -E '^GOOGLE_GEMINI_BASE_URL=' "$_gemini_env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]\r')"
    fi
    if [[ -z "${GEMINI_MODEL:-}" && -z "$cfg_model" ]]; then
      cfg_model="$(grep -E '^GEMINI_MODEL=' "$_gemini_env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]\r')"
    fi
  fi
fi

if [[ -z "$api_key" ]]; then
  echo "[ERROR] No API key found." >&2
  echo "Set GEMINI_API_KEY in env, .env.local, $CONFIG_FILE, or ~/.gemini/.env" >&2
  exit 1
fi

# Resolve GOOGLE_GEMINI_BASE_URL and GEMINI_MODEL
base_url="$(choose_value "GOOGLE_GEMINI_BASE_URL" "${GOOGLE_GEMINI_BASE_URL:-}" "$cfg_base_url")"
base_url="${base_url:-https://linkapi.ai}"
base_url="${base_url%/}"

model="$(choose_value "GEMINI_MODEL" "${GEMINI_MODEL:-}" "$cfg_model")"
model="${model:-gemini-2.0-flash}"

# --- Resolve task text ---

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi

if [[ -z "$task_text" ]]; then
  echo "[ERROR] No task provided. Pass as first argument, use --task, or pipe from stdin." >&2
  exit 1
fi

# --- Build system prompt based on output type ---

case "$output_type" in
  html)
    system_prompt="You are a talented UI/web designer with strong aesthetic taste and creative vision.

Requirements:
- Use realistic placeholder content, not lorem ipsum.
- Add <!-- FEATURE: description --> comments before each functional section explaining what it does.
- Wire up JS interactions so the prototype feels alive and usable.

Everything else — visual style, layout, colors, typography, states, animations, micro-interactions — is up to you. Be creative and opinionated. Don't default to generic styles.

Output a single self-contained HTML file (CSS in <style>, JS in <script>). No external dependencies. Output ONLY the HTML code, no explanation."
    file_ext="html"
    ;;
  svg)
    system_prompt="You are a talented icon and illustration designer. Create a clean, expressive SVG. Style, color, and artistic approach are entirely up to you — be creative. The SVG must have a proper viewBox and be well-structured. Output ONLY the SVG code, no explanation."
    file_ext="svg"
    ;;
  *)
    system_prompt="You are a talented designer and creative director. Give concrete, actionable design advice with specific values (hex colors, fonts, spacing) so it's directly usable. Don't hold back your creative opinion — suggest bold ideas and distinctive visual directions. Respond in the same language as the user's request."
    file_ext="md"
    ;;
esac

# --- Prepare output path ---

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  output_dir="${PWD}/.runtime/gemini-designer"
  mkdir -p "$output_dir"
  output_path="${output_dir}/${timestamp}.${file_ext}"
else
  # On Windows (Git Bash), convert backslashes to forward slashes
  if [[ "$IS_WINDOWS" == true ]]; then
    output_path="${output_path//\\//}"
  fi
fi
mkdir -p "$(dirname "$output_path")"

# --- Build request JSON ---

prompt_file="$(mktemp)"
request_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$request_file"' EXIT

printf "%s" "$task_text" > "$prompt_file"

jq -n \
  --arg model "$model" \
  --arg system "$system_prompt" \
  --rawfile user "$prompt_file" \
  '{
    model: $model,
    messages: [
      { role: "system", content: $system },
      { role: "user", content: $user }
    ]
  }' > "$request_file"

# --- Call API ---

response_file="$(mktemp)"
trap 'rm -f "$prompt_file" "$request_file" "$response_file"' EXIT

api_mode="openai"

# --- Attempt 1: OpenAI-compatible format ---
# Use || true to prevent set -e from exiting on curl failure (e.g. SSL errors)
http_code="$(curl -s -w "%{http_code}" -o "$response_file" \
  -X POST "${base_url}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${api_key}" \
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -H "Accept: application/json" \
  -H "Accept-Language: en-US,en;q=0.9" \
  --connect-timeout 30 \
  --max-time 120 \
  -d @"$request_file")" || http_code="000"

# --- Attempt 2: Fallback to native Gemini API ---
if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "[INFO] OpenAI format failed (HTTP ${http_code}), falling back to native Gemini API..." >&2
  api_mode="native"

  # Build native Gemini request body
  native_request_file="$(mktemp)"
  trap 'rm -f "$prompt_file" "$request_file" "$response_file" "$native_request_file"' EXIT

  jq -n \
    --arg system "$system_prompt" \
    --rawfile user "$prompt_file" \
    '{
      systemInstruction: { parts: [{ text: $system }] },
      contents: [{ parts: [{ text: $user }] }]
    }' > "$native_request_file"

  http_code="$(curl -s -w "%{http_code}" -o "$response_file" \
    -X POST "${base_url}/v1beta/models/${model}:generateContent" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${api_key}" \
    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
    -H "Accept: application/json" \
    --connect-timeout 30 \
    --max-time 120 \
    -d @"$native_request_file")"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "[ERROR] Native Gemini API also failed (HTTP ${http_code})" >&2
    cat "$response_file" >&2
    exit 1
  fi
  echo "[INFO] Native Gemini API succeeded." >&2
fi

# --- Extract content ---

if [[ "$api_mode" == "openai" ]]; then
  content="$(jq -r '.choices[0].message.content // empty' < "$response_file")"
else
  # Native Gemini format: extract text parts, filtering out thought parts
  content="$(jq -r '[.candidates[0].content.parts[] | select(.thought != true) | .text] | join("")' < "$response_file")"
fi

if [[ -z "$content" ]]; then
  echo "[ERROR] Empty response from API" >&2
  jq . < "$response_file" >&2
  exit 1
fi

# For html/svg, strip markdown fences if present
if [[ "$output_type" == "html" || "$output_type" == "svg" ]]; then
  # Remove ```html ... ``` or ```svg ... ``` wrappers
  content="$(echo "$content" | sed -E '/^```(html|svg|xml)?[[:space:]]*$/d')"
fi

printf "%s\n" "$content" > "$output_path"
echo "output_path=$output_path"
