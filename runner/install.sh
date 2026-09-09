#!/usr/bin/env bash
# Everything the Mac needs, in one run: build the image, take the PAT, register the launchd
# agent. Idempotent - running it again rebuilds and restarts rather than duplicating anything.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label='com.zeroxsolutions.actions-runner'
agent="${HOME}/Library/LaunchAgents/${label}.plist"

docker info >/dev/null 2>&1 || {
  echo "Docker is not running. Start Docker Desktop and run this again." >&2
  exit 1
}

if [ ! -f "${here}/.env" ]; then
  cp "${here}/.env.example" "${here}/.env"
  # `-s` so the token never reaches the scrollback, and never a command line another process reads.
  read -rsp 'GitHub PAT (admin:org): ' pat
  echo
  # A literal `|` delimiter: a PAT is base62 plus underscores, so it cannot appear in the token.
  sed -i '' "s|^RUNNER_PAT=.*|RUNNER_PAT=${pat}|" "${here}/.env"
  chmod 600 "${here}/.env"
fi

docker build --platform linux/arm64 -t zeroxsolutions/actions-runner:latest "${here}"

# launchd resolves no variable and no relative path, so the absolute one is substituted here
# rather than left for an editor to get right.
mkdir -p "${HOME}/Library/LaunchAgents"
sed "s|/ABSOLUTE/PATH/TO/runner/run-one-job.sh|${here}/run-one-job.sh|" \
  "${here}/${label}.plist" > "${agent}"

# `bootstrap` answers "5: Input/output error" when the label is already loaded, which every
# re-run is. `bootout` can return before launchd has dropped it, so wait for the label to go
# rather than racing it.
if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  for _ in $(seq 1 50); do
    launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

# Never silent: a bootstrap that fails now says what still holds the label.
if ! launchctl bootstrap "gui/$(id -u)" "${agent}"; then
  echo "bootstrap failed, and launchd still holds ${label}:" >&2
  launchctl print "gui/$(id -u)/${label}" >&2 || true
  exit 1
fi

echo
echo "Installed. The runner is registering now:"
echo "  tail -f /tmp/actions-runner.log     # wait for 'Listening for Jobs'"
echo
echo "Once it is Online, retire this Mac's old runner so jobs stop landing on macOS:"
echo "  launchctl bootout gui/$(id -u)/<the existing runner agent label>"
