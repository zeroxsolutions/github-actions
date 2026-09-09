# runner

The machine side of `runs-on: self-hosted`. Every workflow here names that label; this is what
answers it. Nothing in a workflow file changes to adopt it.

A job runs inside a fresh Linux container on the Mac rather than on the Mac. That is the whole
point: a port a job binds - a dev server, a test database - is the container's, so it cannot
collide with another job, with a dev checkout on the same machine, or with a leftover process
from the run before.

`container:` in a workflow is not the mechanism here and cannot be. `actions/runner`'s
`src/Runner.Worker/ContainerOperationProvider.cs` rejects it twice over: line 49 on any runner
that is not Linux, and line 548 on a runner already inside a container. The container is the
runner instead.

## The shape

```
launchd  -> docker run --rm  -> container up
                             -> entrypoint registers an ephemeral runner
                             -> run.sh: "Listening for Jobs"   <- online before any job
GitHub sends a job           -> it runs in this container
--ephemeral                  -> the runner deregisters, run.sh returns, the container is removed
launchd sees the script exit -> docker run --rm  -> a new container, Listening again
```

One container serves one job, and a container is always up and waiting, so GitHub sees an
ordinary online runner; the ~10-20s between one job ending and the next container registering is
queue time, not a dropped job.

So the two figures differ: the number of containers CREATED is the number of jobs, one each,
never reused; the number alive AT ONCE is the number of slots. Ten jobs against one slot is ten
containers in sequence, nine of them waiting in GitHub's queue.

## Install, once per Mac

```sh
./install.sh                                        # one slot
./install.sh --slots 4                              # four
tail -f /tmp/com.zeroxsolutions.actions-runner.*.log     # wait for 'Listening for Jobs'
```

A slot is one launchd agent, one container, one concurrent job. Re-run with a different count to
change it: the installer drops every agent it registered before bootstrapping the new set, so
lowering the count removes the extra ones rather than leaving them running.

How many a Mac takes is its RAM and CPU, not this script. Each slot runs a full gate.

## Take a Mac back off CI

```sh
./uninstall.sh              # stops the agent, removes the container, deregisters what is stale
./uninstall.sh --purge      # the above, plus the image, the cache volumes and the PAT
```

An ephemeral runner deregisters after a job and not before, so one stopped while idle stays on
the org as offline; the script removes those. Retiring the container is not enough on its own -
put that Mac's original runner back, or it takes no jobs at all.

## Retire that Mac's old runner

The container registers as `self-hosted` and nothing else, which is the label every workflow
here already asks for. So while the old runner is also registered, both match and GitHub picks
whichever is idle - jobs keep landing on macOS. Stop it:

```sh
launchctl bootout gui/$(id -u)/<the existing runner agent label>
```

Reversible: `launchctl bootstrap` the old plist again. Nothing is deleted.

## What the container is trusted with

A job using testcontainers needs the host's docker socket, so the launcher mounts it. On Docker
Desktop that socket is `root:root`, which is why the entrypoint puts the runner user in group 0:
any job that runs here can start containers on the Mac. The grant is wider than the runner
process, and a workflow from a fork would inherit it.

## What each slot keeps

The pnpm store is one volume shared by every slot: it is content-addressed and lock-protected,
which is what lets one store serve many projects at once, and a warm one is tens of gigabytes.
Each slot gets its own mise volume instead - under 1GB, and two containers installing one tool
version into one directory is a race with nothing to gain.

## The Playwright base image

The tag is the org's baseline, not a per-repository pin. A repository on the same
`@playwright/test` finds the browsers already in the image; one on another version installs its
own into `/ms-playwright` at job time and pays a download for that job. Move the tag when most
repositories have moved.
