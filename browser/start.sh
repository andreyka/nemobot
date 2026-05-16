#!/usr/bin/env bash
set -euo pipefail

CHROME_BIN=""
for candidate in \
  /usr/bin/chromium \
  /usr/bin/chromium-browser \
  /usr/bin/google-chrome \
  /usr/bin/google-chrome-stable \
  /opt/google/chrome/chrome
do
  if [[ -x "${candidate}" ]]; then
    CHROME_BIN="${candidate}"
    break
  fi
done

if [[ -z "${CHROME_BIN}" ]]; then
  CHROME_BIN="$(
    find /usr/local/bin/playwright-browsers /usr /opt \
      \( -path '*/chrome-linux/chrome' -o -type f \( -name chromium -o -name chromium-browser -o -name google-chrome -o -name google-chrome-stable -o -name chrome \) \) \
      2>/dev/null | head -n1
  )"
fi

if [[ -z "${CHROME_BIN}" ]]; then
  echo "chrome binary not found" >&2
  exit 1
fi

mkdir -p /tmp/chrome-profile

"${CHROME_BIN}" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --no-first-run \
  --no-default-browser-check \
  --remote-debugging-address=localhost \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/chrome-profile \
  about:blank >/tmp/chrome.log 2>&1 &

for _ in $(seq 1 60); do
  if curl -fsS http://localhost:9222/json/version >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

exec node /opt/openclaw-browser/cdp-proxy.js
