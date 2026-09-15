# github-actions

Shared CI/CD workflows and actions for ZeroXSolutions monorepos, on Nx or on
Turborepo. A product calls them instead of copying them, so a fix made here
reaches every product.

## What is here

| Path | Kind | Purpose |
|---|---|---|
| `nx-setup/action.yml` | composite action | Check out the caller, install its toolchain and dependencies, restore the nx cache. Both nx workflows run it. |
| `.github/workflows/nx-gate.yml` | reusable workflow | Run nx targets. Declares no environment, so a gate cannot reach a deployment credential. |
| `.github/workflows/nx-deploy.yml` | reusable workflow | Run nx deploy targets inside a named environment. |
| `turbo-setup/action.yml` | composite action | The same for a Turborepo workspace, caching `.turbo` instead of `.nx/cache`. |
| `.github/workflows/turbo-gate.yml` | reusable workflow | Run turbo tasks. Declares no environment, so a gate cannot reach a deployment credential. |
| `.github/workflows/turbo-deploy.yml` | reusable workflow | Run turbo deploy tasks inside a named environment. |

Every workflow here names `runs-on: self-hosted`. Each machine registers its own
runner under that label, outside this repository, and nothing here provisions one.

A product on Nx calls the `nx-*` pair and a product on Turborepo calls the
`turbo-*` pair. Both pairs run on the same self-hosted runner, pin the same
third-party SHAs and share no state. The gates take the same inputs. The deploys
differ in one: `nx-deploy` takes `configuration` and `turbo-deploy` `deploy-env`.

Call a `*-gate` or `*-deploy` workflow when a job only runs targets. When the job
needs steps of its own, use the matching `*-setup` action in that job instead,
because a job that calls a reusable workflow cannot add steps to it.

## Versions come from the caller, not from here

Both setup actions install the toolchain with mise, which reads the calling
repository's `.tool-versions`. Nothing here pins a product's toolchain, so a
product upgrading Node changes one file in its own repository and nothing else.

**Turborepo forces a second declaration of pnpm.** Turbo refuses to resolve a
workspace without `devEngines.packageManager` (or the legacy `packageManager`)
in `package.json`, so a turbo product carries its pnpm version in two files.
Keeping them in step is the product's job; nothing here compares them.

An Nx product has no such constraint and should keep `packageManager` out of its
manifest. pnpm switches itself to the version that field names, which gives
different machines different pnpm versions.

## What the machine supplies

A job lands on whichever runner holding the `self-hosted` label is idle, so every
such runner has to be able to run every caller's gate. Setup puts node and pnpm
on `PATH` for the job alone, so the commands below need nothing on the machine
but a shell.

The gates install Playwright's browsers and, on Linux, every system package
Playwright's own table names for them, so a caller that upgrades Playwright gets
the packages the new version names. The machine supplies the rest:

| Missing on the machine | What the gate reports |
|---|---|
| On Linux, passwordless sudo for the runner user, while any package is still missing | `sudo: A terminal is required to authenticate` in `Install Playwright browsers` |
| A library Playwright's table has no package for | a `Browser libraries missing` annotation, and `Missing libraries:` in that step's log |
| For a caller whose tests start containers, a docker daemon the runner's own process can reach | `Could not find a working container runtime strategy` |

### Passwordless sudo

`playwright install-deps` runs `sudo -- sh -c "apt-get ..."`, so a sudoers rule
limited to `apt-get` does not match it. The rule below allows every command, and
with it any job on the machine can run as root. Once every package is installed,
`--dry-run` passes and the step stops calling sudo until a caller's Playwright
upgrade names a new package.

A freshly installed machine lacked 308 of those packages on 2026-09-15, so its
first gate calls sudo, and a reinstalled machine needs the rule again. Check it on
the machine:

```bash
pid=$(pgrep -f Runner.Listener | head -1)
user=$(ps -o user= -p "$pid")               # the user the runner service runs as; the rule names it
echo "runner user: $user"
sudo -u "$user" sudo -n true && echo 'passwordless sudo works'   # "a password is required" means no rule
```

Write the rule, in the same shell as the check above:

```bash
echo "$user ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/actions-runner
sudo chmod 0440 /etc/sudoers.d/actions-runner
sudo visudo -cf /etc/sudoers.d/actions-runner
sudo -u "$user" sudo -n true && echo 'passwordless sudo works'
```

Then rerun only the failed job, from any machine with `gh`. A rerun lands on
whichever runner is idle, so once the job starts, check that its line names the
machine you fixed:

```bash
repo=zeroxsolutions/travel                  # the caller whose gate failed
run=$(gh run list --repo "$repo" --status failure --limit 1 --json databaseId --jq '.[0].databaseId')
gh run rerun "$run" --repo "$repo" --failed
gh api "repos/$repo/actions/runs/$run/jobs" --jq '.jobs[] | "\(.name) \(.status) \(.runner_name)"'
```

### Libraries with no package in Playwright's table

When the table has no package for a missing library, the step's warning lists the
library's file name instead. On Ubuntu 26.04 arm64, playwright-core 1.62.1 has no
package for three that WebKit loads:

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

testcontainers 12.1.0 gives no reason beyond that one line, so check the machine.
The runner's install directory below is the default one:

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
is under the user's runtime directory. Point the runner at it through `.env`,
which the runner reads when it starts. Run this in the same shell as the check
above:

```bash
echo "DOCKER_HOST=unix:///run/user/$(id -u "$user")/docker.sock" | sudo tee -a .env
sudo ./svc.sh stop && sudo ./svc.sh start
```

If the socket exists but `Groups` lacks its gid, the runner user is not in the
group, or joined it after the runner started. A group reaches only the processes
started after it was granted, so the commands below restart the runner. Run them
in the same shell as the check above:

```bash
sudo usermod -aG docker "$user"
sudo ./svc.sh stop && sudo ./svc.sh start
grep Groups /proc/"$(pgrep -f Runner.Listener | head -1)"/status   # now lists the gid
```

## Environments belong to the caller

`nx-deploy` declares its environment from an input, and that environment resolves
against the **calling** repository, so its variables, secrets and protection rules
are the caller's. An experiment confirmed this. The GitHub documentation leaves it
implicit, and at least one published summary of that documentation states the
opposite.

So **this repository holds no product's credentials and cannot come to hold one
by accident**. A caller that names a protected environment has its deploy job
wait for that environment's reviewer.

## Ref pinning policy

| Who pins what | To what | Why |
|---|---|---|
| A product calling this repository | a moving major tag, `@v1` | A fix here reaches every product without opening a pull request in each. |
| This repository calling a third party | a full commit SHA | A third party can move a tag to different code. A SHA pinned here pins that code once for every product instead of once per product. |

Dependabot opens the pull requests that move those SHAs, and each one is reviewed
here, once for every product.

A product that has to stay on an older version of this repository pins a SHA
instead of `@v1` and upgrades by hand. Do that only for a stated reason.

### Releasing

`v1` is a moving tag. Move it only for a change that is backward compatible for
every caller. A change that removes an input, renames one, or alters what a
workflow does to a caller's repository is a new major version. Tag it `v2` and
leave `v1` where it is, so a product takes the break only when it changes its own
pin.

## Calling this repository from a private product

This repository is private, so another repository cannot call its workflows until
the Actions access policy allows it. The policy defaults to `none`, and this
command, run once, sets it:

```bash
gh api -X PUT repos/zeroxsolutions/github-actions/actions/permissions/access \
  -f access_level=organization
```
