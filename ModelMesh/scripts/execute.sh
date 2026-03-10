#!/usr/bin/env bash
# Ensure bash is used, not sh
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi
set -eo pipefail

usage() {
  cat <<'USAGE'
Usage:
  execute.sh <task> [options]

Unified execution partner script that automatically routes tasks to:
  - Codex:  code implementation, refactoring, testing, bug fixes
  - Gemini: UI/UX design, HTML mockups, SVG icons, design advice

Options:
  --partner <codex|gemini|auto>  Force specific partner or auto-detect (default: auto)
  --model <name>                 Override model (shared, works for both partners)
  --file <path>                  File context (repeatable, Codex only)
  --workspace <path>             Workspace directory (Codex only)
  --session <id>                 Resume session (Codex only)
  --reasoning <level>            Reasoning effort: low/medium/high (Codex only)
  --read-only                    Read-only mode (Codex only)
  --html                         Output as HTML (Gemini only)
  --svg                          Output as SVG (Gemini only)
  -o, --output <path>            Output file path (Gemini only)
  --check                        Check if partner scripts are installed, then exit
  -h, --help                     Show this help

Examples:
  execute.sh "Add a power function to calculator and write tests"
  execute.sh "Refactor UserService" --partner codex --file src/services/UserService.ts
  execute.sh "Design a login form" --partner gemini --html
  execute.sh "Fix the memory leak" --file src/WebSocketHandler.ts --reasoning high
USAGE
}

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
GEMINI_SCRIPT="$SCRIPT_DIR/ask_gemini.sh"

# Select Codex script based on OS (Windows uses ask_codex_windows.sh)
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    CODEX_SCRIPT="$SCRIPT_DIR/ask_codex_windows.sh" ;;
  *)
    CODEX_SCRIPT="$SCRIPT_DIR/ask_codex.sh" ;;
esac

# --- Pre-flight check ---
check_dependencies() {
  local missing=0
  if [[ ! -x "$CODEX_SCRIPT" ]]; then
    echo "[WARN] Codex script not found or not executable: $CODEX_SCRIPT" >&2
    missing=1
  fi
  if [[ ! -x "$GEMINI_SCRIPT" ]]; then
    echo "[WARN] Gemini script not found or not executable: $GEMINI_SCRIPT" >&2
    missing=1
  fi
  if [[ $missing -eq 0 ]]; then
    echo "[OK] Both partner scripts are installed." >&2
  fi
  return $missing
}

# --- Parse arguments ---
task_text=""
partner="auto"
model_arg=""
codex_args=()
gemini_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --check)
      check_dependencies; exit $? ;;
    --partner)
      partner="${2:?'--partner requires a value'}"
      shift 2 ;;
    --model)
      model_arg="${2:?'--model requires a value'}"
      shift 2 ;;
    --file)
      codex_args+=(--file "${2:?'--file requires a path'}")
      shift 2 ;;
    --workspace)
      codex_args+=(--workspace "${2:?'--workspace requires a path'}")
      shift 2 ;;
    --session)
      codex_args+=(--session "${2:?'--session requires an id'}")
      shift 2 ;;
    --reasoning)
      codex_args+=(--reasoning "${2:?'--reasoning requires a level'}")
      shift 2 ;;
    --read-only)
      codex_args+=(--read-only)
      shift ;;
    --html)
      gemini_args+=(--html)
      shift ;;
    --svg)
      gemini_args+=(--svg)
      shift ;;
    -o|--output)
      gemini_args+=(-o "${2:?'-o requires a path'}")
      shift 2 ;;
    -*)
      echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$task_text" ]]; then
        task_text="$1"
      else
        echo "[ERROR] Multiple positional arguments not allowed" >&2; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$task_text" ]]; then
  echo "[ERROR] Task text is required" >&2
  usage; exit 1
fi

# --model: pass to Codex via flag; Gemini reads GEMINI_MODEL env var
if [[ -n "$model_arg" ]]; then
  codex_args+=(--model "$model_arg")
  export GEMINI_MODEL="$model_arg"
fi

# --- Weighted keyword auto-detection ---
# Uses a score: +N for design signals, -N for code signals.
# Threshold > 0 → Gemini; otherwise → Codex.
# This prevents single ambiguous words (button, form, page) from
# flipping the decision when the overall intent is clearly about code.

detect_partner() {
  local text
  text="$(echo "$1" | tr '[:upper:]' '[:lower:]')"   # lowercase (bash 3.2 compatible)
  local score=0

  # Strong design signals (+2)
  local design2=(mockup "ui design" "ux design" "landing page" "color palette" typography "visual design" "design a " "design the ")
  for kw in "${design2[@]}"; do
    [[ "$text" == *"$kw"* ]] && (( score += 2 ))
  done

  # Weak design signals (+1)
  local design1=(icon svg html layout color palette visual style)
  for kw in "${design1[@]}"; do
    [[ "$text" == *"$kw"* ]] && (( score += 1 ))
  done

  # Ambiguous words that are often code context (-1 to neutralize design score)
  local code_context=(handler validate validation route middleware controller service hook component props state)
  for kw in "${code_context[@]}"; do
    [[ "$text" == *"$kw"* ]] && (( score -= 1 ))
  done

  # Strong code signals (-2)
  local code2=(refactor "write tests" "unit test" "fix bug" "memory leak" implement "add function" "add method" "debug ")
  for kw in "${code2[@]}"; do
    [[ "$text" == *"$kw"* ]] && (( score -= 2 ))
  done

  if (( score > 0 )); then
    echo "gemini"
  else
    echo "codex"
  fi
}

if [[ "$partner" == "auto" ]]; then
  partner="$(detect_partner "$task_text")"
  echo "[INFO] Auto-detected partner: $partner" >&2
fi

# --- Execute with selected partner ---
case "$partner" in
  codex)
    if [[ ! -x "$CODEX_SCRIPT" ]]; then
      echo "[ERROR] Codex script not found or not executable: $CODEX_SCRIPT" >&2
      echo "       Run with --check to verify installation." >&2
      exit 1
    fi
    echo "[INFO] Executing with Codex..." >&2
    exec "$CODEX_SCRIPT" "$task_text" "${codex_args[@]+"${codex_args[@]}"}"
    ;;

  gemini)
    if [[ ! -x "$GEMINI_SCRIPT" ]]; then
      echo "[ERROR] Gemini script not found or not executable: $GEMINI_SCRIPT" >&2
      echo "       Run with --check to verify installation." >&2
      exit 1
    fi
    echo "[INFO] Executing with Gemini Designer..." >&2
    exec "$GEMINI_SCRIPT" "$task_text" "${gemini_args[@]+"${gemini_args[@]}"}"
    ;;

  *)
    echo "[ERROR] Invalid partner: '$partner' (valid: codex, gemini, auto)" >&2
    exit 1
    ;;
esac
