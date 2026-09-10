#!/usr/bin/env bash
# Takes this Mac back off CI: stops every agent this installer registered, discards their
# containers, and deregisters what the runners left behind. Add `--purge` to also drop the image,
# the cache volumes and the PAT.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix='com.zeroxsolutions.actions-runner'
uid="$(id -u)"
image="${RUNNER_IMAGE:-zeroxsolutions/actions-runner:latest}"
purge=false
[ "${1:-}" = '--purge' ] && purge=true

# First, and every slot, or launchd starts a replacement container the moment one is removed.
# `index() == 1` and not a regex: the prefix is full of dots.
for label in $(launchctl list | awk -v p="${prefix}" 'index($3, p) == 1 { print $3 }'); do
  launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
  for _ in $(seq 1 50); do
    launchctl print "gui/${uid}/${label}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  rm -f "${HOME}/Library/LaunchAgents/${label}.plist"
  echo "stopped ${label}"
done

# The daemon owns the container, so killing the `docker run` client leaves it running. Found by
# LABEL: measured 2026-09-10, `--filter ancestor=<tag>` stops matching a running container the
# moment that tag is rebuilt, so it finds nothing after any reinstall.
running=$(docker ps -aq --filter "label=${prefix}" || true)
if [ -n "${running}" ]; then
  # shellcheck disable=SC2086 -- one id per line, and each is a hex string with no field to split
  docker rm -f ${running} >/dev/null
  echo "containers removed"
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
  volumes=$(docker volume ls -q --filter 'name=actions-runner-' || true)
  if [ -n "${volumes}" ]; then
    # shellcheck disable=SC2086 -- one name per line, and none carries a field separator
    docker volume rm ${volumes} >/dev/null 2>&1 || true
  fi
  docker image rm "${image}" >/dev/null 2>&1 || true
  rm -f "${here}/.env"
  echo "image, volumes and .env removed"
fi

echo
echo "This Mac now takes no jobs. To put its original runner back:"
echo "  launchctl bootstrap gui/${uid} ~/Library/LaunchAgents/<the old runner agent>.plist"
