#!/usr/bin/env bash
# Everything the Mac needs, in one run: build the image, take the PAT, and register one launchd
# agent per slot. Idempotent - running it again rebuilds and re-registers rather than adding.
#
# One slot is one container and one concurrent job. Four slots is four containers at once, which
# is only safe because each has its own network namespace; before that the ports met.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix='com.zeroxsolutions.actions-runner'
uid="$(id -u)"
slots=1

while [ $# -gt 0 ]; do
  case "$1" in
    --slots) slots="${2:?--slots needs a count}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "${slots}" in
  '' | *[!0-9]* | 0) echo "--slots takes a positive integer" >&2; exit 1 ;;
esac

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

# Every agent this script has ever registered goes, whatever last run's slot count was - lowering
# the count must not leave the extra agents running. `index() == 1` and not a regex: the prefix
# is full of dots.
#
# `bootstrap` answers "5: Input/output error" when the label is already loaded, and `bootout` can
# return before launchd has dropped it, so wait for the label to go rather than racing it.
mkdir -p "${HOME}/Library/LaunchAgents"
for label in $(launchctl list | awk -v p="${prefix}" 'index($3, p) == 1 { print $3 }'); do
  launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
  for _ in $(seq 1 50); do
    launchctl print "gui/${uid}/${label}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  rm -f "${HOME}/Library/LaunchAgents/${label}.plist"
done

# The daemon owns the container, so booting an agent out leaves its container running, still
# registered, and still taking jobs - from the image built before this run, which is the image
# this run exists to replace. `rm -f` and not a drain: PID 1 is `sg ... -c ./run.sh`, sg forwards
# no signal, so `docker stop` waits out its whole timeout and kills anyway (measured 2026-09-10).
# A job in flight therefore fails, loudly, where one served from the previous image fails silently.
stale=$(docker ps -aq --filter "label=${prefix}" || true)
if [ -n "${stale}" ]; then
  # shellcheck disable=SC2086 -- one id per line, and each is a hex string with no field to split
  docker rm -f ${stale} >/dev/null
  echo "removed $(printf '%s\n' ${stale} | wc -l | tr -d ' ') container(s) the old agents left"
fi

for slot in $(seq 1 "${slots}"); do
  label="${prefix}.${slot}"
  agent="${HOME}/Library/LaunchAgents/${label}.plist"
  # launchd resolves no variable and no relative path, so the absolute one is substituted here.
  sed -e "s|__LABEL__|${label}|g" \
      -e "s|__PROGRAM__|${here}/run-one-job.sh|" \
      -e "s|__SLOT__|${slot}|" \
      -e "s|__LOG__|/tmp/${label}.log|g" \
      "${here}/${prefix}.plist" > "${agent}"

  # Never silent: a bootstrap that fails says what still holds the label.
  if ! launchctl bootstrap "gui/${uid}" "${agent}"; then
    echo "bootstrap failed for ${label}, and launchd still holds it:" >&2
    launchctl print "gui/${uid}/${label}" >&2 || true
    exit 1
  fi
  echo "slot ${slot} registered as ${label}"
done

echo
echo "${slots} slot(s) installed - ${slots} container(s), so ${slots} concurrent job(s)."
echo "  tail -f /tmp/${prefix}.*.log     # wait for 'Listening for Jobs'"
echo
echo "Once they are Online, retire this Mac's old runner so jobs stop landing on macOS:"
echo "  launchctl bootout gui/${uid}/<the existing runner agent label>"
