#!/usr/bin/env bash
# Registers one ephemeral runner, serves exactly one job, and exits - the launcher then
# discards the container, so the next job starts on a filesystem nothing has written to.
set -euo pipefail

: "${RUNNER_ORG:?set RUNNER_ORG to the GitHub organisation the runner joins}"
: "${RUNNER_PAT:?set RUNNER_PAT to a token with admin:org, used only to mint a registration token}"
# `self-hosted` and nothing else, deliberately: it is the label `nx-gate.yml` already asks for,
# so no repository in the org changes a line. A new label would have to be adopted by all of them.
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"

# A registration token lasts one hour and one registration, so it cannot be a stored value:
# every container mints its own from the PAT.
registration_token=$(
  curl -fsS -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer ${RUNNER_PAT}" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/orgs/${RUNNER_ORG}/actions/runners/registration-token" \
  | jq -r '.token'
)

# The socket belongs to the host, so its group id is whatever the host assigned and is unknown
# until now; adopting that id is the only way the runner user can drive testcontainers.
docker_group=''
if [ -S /var/run/docker.sock ]; then
  socket_gid=$(stat -c '%g' /var/run/docker.sock)
  getent group "${socket_gid}" >/dev/null || sudo groupadd --gid "${socket_gid}" docker-host
  docker_group=$(getent group "${socket_gid}" | cut -d: -f1)
  sudo usermod --append --groups "${docker_group}" runner
fi

# `--ephemeral` is what makes one container one job: the runner takes a single job, deregisters
# itself, and `run.sh` returns. The container hostname is unique per container, so two of them
# never contend for one registration name.
./config.sh \
  --unattended \
  --ephemeral \
  --replace \
  --url "https://github.com/${RUNNER_ORG}" \
  --token "${registration_token}" \
  --name "container-$(hostname)" \
  --labels "${RUNNER_LABELS}" \
  --work /home/runner/_work

# `usermod` writes the group file and not this process, so the new membership reaches `run.sh`
# only through a shell that re-reads it.
if [ -n "${docker_group}" ]; then
  exec sg "${docker_group}" -c ./run.sh
fi
exec ./run.sh
