#!/usr/bin/env bash
# Starts one container, which serves one job and exits. launchd restarts this script, so the
# next job gets a container built from the image again rather than the one just used.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="${RUNNER_IMAGE:-zeroxsolutions/actions-runner:latest}"

# The named volumes are the only state that survives a job. Without them `pnpm install` and
# mise re-download the whole toolchain every run, which is what the image cannot cache: the
# store lives in the home directory, and the home directory goes with the container.
exec docker run --rm \
  --env-file "${here}/.env" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume actions-runner-pnpm:/home/runner/.local/share/pnpm \
  --volume actions-runner-mise:/home/runner/.local/share/mise \
  --add-host host.docker.internal:host-gateway \
  --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal \
  "${image}"
