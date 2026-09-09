#!/usr/bin/env bash
# Starts one container, which serves one job and exits. launchd restarts this script, so the
# next job gets a container built from the image again rather than the one just used.
#
# The slot number comes from the launchd agent that calls this; it names that slot's own volume.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slot="${1:-1}"
image="${RUNNER_IMAGE:-zeroxsolutions/actions-runner:latest}"

# The named volumes are the only state that survives a job. Without them `pnpm install` and mise
# re-download the whole toolchain every run, which is what the image cannot cache: the store
# lives in the home directory, and the home directory goes with the container.
#
# The pnpm store is SHARED by every slot - it is content-addressed and lock-protected, which is
# what makes one store serve many projects at once - while mise gets one volume per slot,
# because two containers installing the same tool version into one directory is a race. Measured
# 2026-09-10: a warm store is tens of GB and a mise directory is under 1GB, so this is the split
# that fits on a Mac.
exec docker run --rm \
  --env-file "${here}/.env" \
  --volume /var/run/docker.sock:/var/run/docker.sock \
  --volume actions-runner-pnpm:/home/runner/.local/share/pnpm \
  --volume "actions-runner-mise-${slot}:/home/runner/.local/share/mise" \
  --add-host host.docker.internal:host-gateway \
  --env TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal \
  "${image}"
