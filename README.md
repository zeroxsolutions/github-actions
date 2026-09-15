# github-actions

Shared CI/CD building blocks for ZeroXSolutions monorepos - Nx and Turborepo
alike. Products **call** what lives here; they do not copy it. One fix lands
once, for everyone.

## What is here

| Path | Kind | Purpose |
|---|---|---|
| `nx-setup/action.yml` | composite action | Check out the caller, install its toolchain and dependencies, restore the nx cache. The one definition of "ready to run nx targets". |
| `.github/workflows/nx-gate.yml` | reusable workflow | Run nx targets. Declares **no** environment, so a gate cannot reach a deployment credential. |
| `.github/workflows/nx-deploy.yml` | reusable workflow | Run nx deploy targets inside a named environment. |
| `turbo-setup/action.yml` | composite action | The same, for a Turborepo workspace: caches `.turbo` instead of `.nx/cache`. |
| `.github/workflows/turbo-gate.yml` | reusable workflow | Run turbo tasks. Declares **no** environment, so a gate cannot reach a deployment credential. |
| `.github/workflows/turbo-deploy.yml` | reusable workflow | Run turbo deploy tasks inside a named environment. |

Every workflow here names `runs-on: self-hosted`. What answers that label is
registered on each machine and lives outside this repository; nothing here
provisions a runner.

**Pick the pair that matches the caller's task runner.** The two sets are
structurally identical and deliberately kept so: same inputs, same self-hosted
runner, same pinned third-party SHAs. A product on Nx calls the `nx-*` pair; a
product on Turborepo calls the `turbo-*` pair. Nothing shares state between them.

**Which one to use.** Call the `*-gate` / `*-deploy` workflow when a job only
needs to run targets. Compose the matching `*-setup` action directly in your own
job when the job also needs steps of its own - a job that delegates to a reusable
workflow cannot add steps to it.

## Versions come from the caller, not from here

Both setup actions install the toolchain with mise, which reads the calling
repository's `.tool-versions`. Nothing here pins a product's toolchain, so a
product upgrading Node changes one file in its own repository and nothing else.

**Turborepo forces a second declaration of pnpm.** Turbo refuses to resolve a
workspace without `devEngines.packageManager` (or the legacy `packageManager`)
in `package.json`, so a turbo product carries its pnpm version in two files
whether it wants to or not. Keeping them in step is the product's job; nothing
here compares them.

An Nx product has no such constraint and should keep `packageManager` out of its
manifest: the field self-switches, which gives different machines different pnpm
versions.

## What the machine supplies

A job lands on whichever runner holding the `self-hosted` label is idle, so each
of them has to be able to run every caller's gate. Setup puts node and pnpm on
`PATH` for the job alone, so every command below runs on the machine with nothing
but a shell.

The gates install Playwright's browsers and, on Linux, every system package
Playwright's own table names for them, so a Playwright upgrade in a caller brings
its libraries with it. The machine supplies the rest:

| Missing on the machine | What the gate reports |
|---|---|
| On Linux, passwordless sudo for the runner user, while any package is still missing | `Install Playwright browsers` fails inside `playwright install-deps` |
| A library Playwright's table has no package for | a `Browser libraries missing` annotation, and `Missing libraries:` in that step's log |
| For a caller whose tests start containers, a docker daemon the runner's own process can reach | `Could not find a working container runtime strategy` |

### Passwordless sudo

`playwright install-deps` runs `sudo -- sh -c "apt-get ..."`, so a rule limited to
`apt-get` does not match it, and any job on the machine can run as root. Once
every package is in, `--dry-run` passes and the step stops calling sudo, until a
caller's Playwright upgrade names a new package.

```bash
pid=$(pgrep -f Runner.Listener | head -1)
user=$(ps -o user= -p "$pid")
echo "$user ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/actions-runner
sudo chmod 0440 /etc/sudoers.d/actions-runner
sudo visudo -cf /etc/sudoers.d/actions-runner
sudo -u "$user" sudo -n true && echo 'passwordless sudo works'
```

### Libraries with no package in Playwright's table

When the table has no package for a missing library, the step's warning lists the
library name instead. On Ubuntu 26.04 arm64, playwright-core 1.62.1 has no package
for three that WebKit loads:

```bash
sudo apt-get install -y --no-install-recommends libgraphene-1.0-0 libvulkan1 libwebpmux3
```

For any other name the warning lists, find the package on the machine:

```bash
sudo apt-get install -y apt-file && sudo apt-file update   # once
ldconfig -p | grep -F libvulkan.so.1                       # prints nothing while it is missing
apt-file search libvulkan.so.1                             # names the package that ships it
```

### Docker access

testcontainers gives no reason beyond that one line (testcontainers 12.1.0), so
check the machine. The runner's install directory below is the default one:

```bash
cd /home/runner/actions-runner
pid=$(pgrep -f Runner.Listener | head -1)
user=$(ps -o user= -p "$pid")
echo "runner user: $user"
ls -l /var/run/docker.sock                  # the socket and the group that owns it
getent group docker                         # that group's gid
grep Groups /proc/"$pid"/status             # the runner process must list that gid
```

No socket at `/var/run/docker.sock` usually means a rootless daemon, whose socket
sits under the user's runtime directory. Point the runner at it through `.env`,
which the runner reads when it starts (same shell as the check above):

```bash
echo "DOCKER_HOST=unix:///run/user/$(id -u "$user")/docker.sock" | sudo tee -a .env
sudo ./svc.sh stop && sudo ./svc.sh start
```

A socket present but its gid missing from `Groups` means the runner is not in
the group, or joined it after it started - a group reaches only a process started
after it. Same shell as the check above:

```bash
sudo usermod -aG docker "$user"
sudo ./svc.sh stop && sudo ./svc.sh start
grep Groups /proc/"$(pgrep -f Runner.Listener | head -1)"/status   # now lists the gid
```

### Memory

nx runs three tasks at once by default (nx 23.1.0), vitest starts one worker per
vCPU minus one, and each worker of a suite that starts containers holds its own
Postgres container. So a gate's peak grows with the machine's vCPUs and with its
three heaviest tasks, not with the number of projects. Another project makes the
gate longer and leaves the peak where it was.

travel's gate on 2026-09-15, run with `VITEST_MAX_WORKERS=3` as on a 4-vCPU machine
and sampled about every two seconds, peaked at about 3.4 GB of processes plus 0.4 GB across
ten Postgres containers. The OS, dockerd and the runner add roughly 1 GB more, and
a 4 GB machine ran out of memory.

| Machine | Fits |
|---|---|
| 4 vCPU, 8 GB | travel's gate today, with about 3 GB spare |
| 4 vCPU, 16 GB | Recommended. Room for another Next app, or another package whose tests start containers |
| 8 vCPU, 16 to 24 GB | a faster gate; vitest doubles its workers with the vCPUs, so memory grows with them |

Give the machine 50 GB of disk for images, the pnpm store and the browsers, and
4 GB of swap, so a gate short of memory slows down instead of being killed (not yet
run on a runner here):

```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

To see how close a machine runs, watch it during a gate, and check after one:

```bash
free -m -s 5
journalctl -k | grep -i 'out of memory'
```

## Environments belong to the caller

`nx-deploy` declares its environment from an input, and that environment resolves
against the **calling** repository - its variables, its secrets, its protection
rules. Verified by experiment, because the GitHub documentation does not state
it plainly and at least one published summary of that documentation states the
opposite.

The consequence worth keeping: **this repository holds no product's credentials
and cannot**, even by accident. A protected environment name in the caller pauses
the deploy job there for a reviewer.

## Ref pinning policy

| Who pins what | To what | Why |
|---|---|---|
| A product calling this repository | a moving major tag, `@v1` | A fix here reaches every product without opening a pull request in each. That is the entire reason for hosting once. |
| This repository calling a third party | a full commit SHA | This is where supply-chain risk actually sits, and pinning it here pins it once for every product instead of once per product. |

Dependabot in this repository keeps those SHAs current; each bump is reviewed
here, once.

A product that must deliberately lag this repository pins a SHA instead of `@v1`
and accepts manual upgrades. Do that only for a stated reason.

### Releasing

`v1` is a moving tag. Move it only for a change that is backward compatible for
every caller. A change that removes an input, renames one, or alters what a
workflow does to a caller's repository is a **new major** - cut `v2` and leave
`v1` where it is, so no product breaks on a schedule it did not choose.

## Calling this repository from a private product

This repository is private, so its workflows are not callable from another
repository until its Actions access policy is widened. It defaults to `none`:

```bash
gh api -X PUT repos/zeroxsolutions/github-actions/actions/permissions/access \
  -f access_level=organization
```

That is a one-time, API-settable step - no dashboard visit required.
