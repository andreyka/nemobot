#!/usr/bin/env bash
set -euo pipefail

REAL_CLAUDE_BIN="${CLAUDE_REAL_BIN:-}"
if [[ -z "${REAL_CLAUDE_BIN}" ]]; then
  for candidate in \
    /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.real.exe \
    /usr/local/bin/claude-real
  do
    if [[ -x "${candidate}" ]]; then
      REAL_CLAUDE_BIN="${candidate}"
      break
    fi
  done
fi

if [[ ! -x "${REAL_CLAUDE_BIN}" ]]; then
  echo "claude wrapper: real Claude binary not found at ${REAL_CLAUDE_BIN}" >&2
  exit 127
fi

if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" && -n "${NEMOBOT_ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  export ANTHROPIC_AUTH_TOKEN="${NEMOBOT_ANTHROPIC_AUTH_TOKEN}"
fi

sanitized=()
has_verbose=0
uses_stream_json=0
while (($#)); do
  case "$1" in
    --dangerously-skip-permissions)
      shift
      ;;
    --verbose)
      has_verbose=1
      sanitized+=("$1")
      shift
      ;;
    --permission-mode)
      if (($# >= 2)); then
        mode="$2"
        sanitized+=(--permission-mode "${mode}")
        shift 2
      else
        sanitized+=(--permission-mode default)
        shift
      fi
      ;;
    --permission-mode=*)
      sanitized+=("$1")
      shift
      ;;
    --output-format)
      sanitized+=("$1")
      if (($# >= 2)); then
        if [[ "$2" == "stream-json" ]]; then
          uses_stream_json=1
        fi
        sanitized+=("$2")
        shift 2
      else
        shift
      fi
      ;;
    --output-format=*)
      if [[ "${1#--output-format=}" == "stream-json" ]]; then
        uses_stream_json=1
      fi
      sanitized+=("$1")
      shift
      ;;
    *)
      sanitized+=("$1")
      shift
      ;;
  esac
done

if ((uses_stream_json && !has_verbose)); then
  sanitized+=(--verbose)
fi

prepare_path_for_sandbox() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  local current="${path}"
  if [[ -e "${current}" ]]; then
    chown -R sandbox:sandbox "${current}" 2>/dev/null || true
  fi
  while true; do
    current="$(dirname "${current}")"
    [[ "${current}" == "." || "${current}" == "/" ]] && break
    if [[ -e "${current}" ]]; then
      chown sandbox:sandbox "${current}" 2>/dev/null || true
    fi
    [[ "${current}" == "/tmp" || "${current}" == "/home" || "${current}" == "/home/sandbox" ]] && break
  done
}

if [[ "$(id -u)" == "0" ]] && id -u sandbox >/dev/null 2>&1; then
  prepare_path_for_sandbox /home/sandbox/.claude
  prepare_path_for_sandbox /home/sandbox/.claude.json

  for ((i=0; i<${#sanitized[@]}; i++)); do
    case "${sanitized[$i]}" in
      --mcp-config|--plugin-dir|--append-system-prompt-file)
        if (( i + 1 < ${#sanitized[@]} )); then
          prepare_path_for_sandbox "${sanitized[$((i + 1))]}"
        fi
        ;;
      --mcp-config=*|--plugin-dir=*|--append-system-prompt-file=*)
        prepare_path_for_sandbox "${sanitized[$i]#*=}"
        ;;
    esac
  done

  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid sandbox --regid sandbox --init-groups env HOME=/home/sandbox PATH="${PATH}" "${REAL_CLAUDE_BIN}" "${sanitized[@]}"
  fi
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u sandbox -- env HOME=/home/sandbox PATH="${PATH}" "${REAL_CLAUDE_BIN}" "${sanitized[@]}"
  fi
fi

exec "${REAL_CLAUDE_BIN}" "${sanitized[@]}"
