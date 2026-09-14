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
`PATH` for the job alone, so everything below runs on the machine with nothing
but a shell. A machine missing either of these fails inside a caller's `test`
target, not in setup:

| Missing on the machine | What the gate reports |
|---|---|
| On Linux, the system libraries Playwright's browsers link against | `browserType.launch: Host system is missing dependencies to run browsers` |
| For a caller whose tests start containers, a docker daemon the runner's own process can reach | `Could not find a working container runtime strategy` |

### Browser libraries

Every package two gate runs asked for, on Ubuntu 26.04 arm64 with playwright-core
1.62.1. A Mac runner needs none: Playwright checks for them on Linux only.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
  libcairo-gobject2 libcairo2 libcups2t64 libgbm1 libgdk-pixbuf-2.0-0 \
  libgtk-3-0t64 libpango-1.0-0 libpangocairo-1.0-0 libxcomposite1 libxcursor1 \
  libxdamage1 libxfixes3 libxrandr2
```

The gate's `Install Playwright browsers` step stays green while any are missing,
and prints a warning instead. That warning stops at the first browser missing
something, so a later run can name packages this list lacks: install the ones it
lists after `Alternatively, use apt:`, and repeat until the step prints nothing.

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
