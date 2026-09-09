#!/usr/bin/env bash
# Takes this Mac back off CI: stops the agent, discards the container, and deregisters what the
# runner left behind. Add `--purge` to also drop the image, the cache volumes and the PAT.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label='com.zeroxsolutions.actions-runner'
agent="${HOME}/Library/LaunchAgents/${label}.plist"
image="${RUNNER_IMAGE:-zeroxsolutions/actions-runner:latest}"
purge=false
[ "${1:-}" = '--purge' ] && purge=true

# First, or launchd starts a replacement container the moment this one is removed.
launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
rm -f "${agent}"
echo "agent stopped"

# The daemon owns the container, so killing the `docker run` client leaves it running.
running=$(docker ps -q --filter "ancestor=${image}" || true)
if [ -n "${running}" ]; then
  # shellcheck disable=SC2086 -- one id per line, and each is a hex string with no field to split
  docker rm -f ${running} >/dev/null
  echo "container removed"
fi

# `--ephemeral` deregisters after a job and not before, so a runner stopped while idle stays on
# the org as offline. Only ones this script's containers registered are touched.
if [ -f "${here}/.env" ]; then
  set -a
  # shellcheck disable=SC1091 -- written by install.sh, next to this script
  . "${here}/.env"
  set +a
  python3 - "${RUNNER_ORG}" "${RUNNER_PAT}" <<'PY'
import json, sys, urllib.request

org, pat = sys.argv[1], sys.argv[2]
def call(method, path):
    req = urllib.request.Request(f"https://api.github.com{path}", method=method)
    req.add_header("Authorization", f"Bearer {pat}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    with urllib.request.urlopen(req) as r:
        return json.load(r) if r.length != 0 else None

stale = [r for r in call("GET", f"/orgs/{org}/actions/runners?per_page=100")["runners"]
         if r["name"].startswith("container-") and r["status"] != "online"]
for r in stale:
    call("DELETE", f"/orgs/{org}/actions/runners/{r['id']}")
    print(f"deregistered {r['name']}")
print(f"{len(stale)} stale registration(s) removed")
PY
fi

if [ "${purge}" = true ]; then
  docker volume rm actions-runner-pnpm actions-runner-mise >/dev/null 2>&1 || true
  docker image rm "${image}" >/dev/null 2>&1 || true
  rm -f "${here}/.env"
  echo "image, volumes and .env removed"
fi

echo
echo "This Mac now takes no jobs. To put its original runner back:"
echo "  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<the old runner agent>.plist"
