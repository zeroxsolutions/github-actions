# github-actions

Shared CI/CD workflows and actions for ZeroXSolutions monorepos, on Nx or on
Turborepo. A product calls them instead of copying them, so a fix made here
reaches every product.

## What is here

| Path | Kind | Purpose |
|---|---|---|
| `nx-setup/action.yml` | composite action | Check out the caller, install its toolchain and dependencies, point its nx cache at the machine's disk. Both nx workflows run it. |
| `.github/workflows/nx-gate.yml` | reusable workflow | Run nx targets. Declares no environment, so a gate cannot reach a deployment credential. |
| `.github/workflows/nx-deploy.yml` | reusable workflow | Run nx deploy targets inside a named environment. |
| `turbo-setup/action.yml` | composite action | The same for a Turborepo workspace, pointing `TURBO_CACHE_DIR` instead of `NX_CACHE_DIRECTORY`. |
| `.github/workflows/turbo-gate.yml` | reusable workflow | Run turbo tasks. Declares no environment, so a gate cannot reach a deployment credential. |
| `.github/workflows/turbo-deploy.yml` | reusable workflow | Run turbo deploy tasks inside a named environment. |

Every workflow here names `runs-on: self-hosted`. Each machine registers its own
runner under that label, outside this repository, and nothing here provisions one.

A product on Nx calls the `nx-*` pair and a product on Turborepo calls the
`turbo-*` pair. Both pairs run on the same self-hosted runner, pin the same
third-party SHAs and share no state. The gates take the same inputs, except `exclude`, which only `nx-gate` takes. The deploys
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

## The cache lives on the machine, not in GitHub's

Both setup actions point the task runner's cache at a directory under the runner
user's home:

| Workspace | Directory | Cap |
|---|---|---|
| Nx, task outputs | `~/.cache/nx-ci/<owner>/<repo>/artifacts` | `NX_MAX_CACHE_SIZE=2GB`, set by the action |
| Nx, the metadata naming them | `~/.cache/nx-ci/<owner>/<repo>/metadata` | none |
| Turborepo | `~/.cache/turbo-ci/<owner>/<repo>` | none; turbo has no counterpart |

**Nx needs both, and moving one without the other is worse than moving neither.** The
outputs live in `NX_CACHE_DIRECTORY` and the metadata naming them in
`NX_WORKSPACE_DATA_DIRECTORY`, whose default is `.nx/workspace-data`, inside the
workspace. A job that keeps the outputs and loses the metadata opens a full cache it
is not allowed to read and says so:

```
Nx found unrecognized artifacts in the cache directory and will not be able to use them.
Nx can only restore artifacts it has metadata about.
```

Every gate read `Cache: 0/118 hit (0%)` while that was true, under `actions/cache`
first and then on the machine, because neither carried the metadata. A runner that
ran gates before this version holds artifacts no metadata will ever name. Delete them
once, on the machine:

```bash
rm -rf ~/.cache/nx-ci
```

Both runners default to a directory inside the workspace, and checkout empties
that. A runner holding the `self-hosted` label keeps its disk between jobs, which
the pnpm store has always relied on, so the machine holds the cache and no job
uploads or downloads one.

`actions/cache` held it before, under a key ending in the commit SHA. A new commit
matches no existing key, so every job wrote an entry and no job read one back
exactly, and each entry was larger than the last because `restore-keys` handed it
the previous one to add to. travel carried 25 of them, 10.8 GB against GitHub's
10 GB per repository, and each job moved about half a gigabyte each way to keep
them.

A repository that was calling an older version still has those entries. Delete
them once:

```bash
repo=zeroxsolutions/travel
gh api "repos/$repo/actions/caches?per_page=100" \
  --jq '.actions_caches[] | select(.key | test("^(nx|turbo)-")) | .id' \
  | xargs -I{} gh api -X DELETE "repos/$repo/actions/caches/{}"
gh api "repos/$repo/actions/caches" --jq '.total_count'   # what is left is mise's own
```

Nothing trims a Turborepo cache. Run this on the machine when its disk gets tight:

```bash
find "$HOME/.cache/turbo-ci" -type f -atime +14 -delete
```

## What the machine supplies

A job lands on whichever runner holding the `self-hosted` label is idle, so every
such runner has to be able to run every caller's gate. Setup puts node and pnpm on
`PATH` for the job alone, so the commands below need nothing on the machine but a
shell.

The gates install Playwright's browsers and every system package Playwright's own
table names for them, so a caller that upgrades Playwright gets the packages the
new version names. The machine's own package manager supplies the rest, and a
machine that has never run a gate is missing most of it:

| Missing on the machine | What the gate reports |
|---|---|
| Passwordless sudo for the runner user, while any package is still missing | `sudo: A terminal is required to authenticate` in `Install Playwright browsers` |
| A library Playwright's table has no package for | a `Browser libraries missing` annotation, and `Missing libraries:` in that step's log |
| For a caller whose tests start containers, a docker daemon the runner's own process can reach | `Could not find a working container runtime strategy` |

### Passwordless sudo

`playwright install-deps` installs through `sudo -- sh -c`, so a sudoers rule
limited to the package manager does not match it. The rule below allows every
command, and with it any job on the machine can run as root. Once every package is
installed, `--dry-run` passes and the step stops calling sudo until a caller's
Playwright upgrade names a new one.

Check it on the machine:

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

### Libraries with no package in Playwright's table

The warning lists the missing library's file name instead of a package, and the
machine's owner installs whatever ships it. `playwright install` is what checks the
libraries themselves, so the warning comes back on every gate until the machine has
them.

### Docker access

testcontainers gives no reason beyond that one line, so check the machine:

```bash
user=$(ps -o user= -p "$(pgrep -f Runner.Listener | head -1)")   # the user the runner service runs as
echo "runner user: $user"
sudo -u "$user" docker info > /dev/null && echo 'the runner user reaches a daemon'
```

A daemon the runner user cannot reach is usually one listening on a socket that is
not the default. `DOCKER_HOST` reaches the runner through the `.env` file in its
install directory, which it reads when its service starts. Run this in the same
shell as the check above:

```bash
cd ~/actions-runner                                              # the runner's install directory
host=$(sudo -u "$user" docker context inspect --format '{{.Endpoints.docker.Host}}')
echo "DOCKER_HOST=$host" | sudo tee -a .env
sudo ./svc.sh stop && sudo ./svc.sh start
sudo -u "$user" docker info > /dev/null && echo 'the runner user reaches a daemon'
```

If the socket is there and the runner still cannot reach it, the runner user is not
in the group that owns it, or joined after the runner started. A group reaches only
the processes started after it was granted, so restarting the service is part of
the fix.

## Environments belong to the caller

`nx-deploy` declares its environment from an input, and that environment resolves
against the **calling** repository, so its variables, secrets and protection rules
are the caller's. An experiment confirmed this. The GitHub documentation leaves it
implicit, and at least one published summary of that documentation states the
opposite.

So **this repository holds no product's credentials and cannot come to hold one
by accident**. A caller that names a protected environment has its deploy job
wait for that environment's reviewer.

The gates take one secret, `EXPO_TOKEN`, optional, for a caller whose `build`
target runs EAS Build. The caller passes it by name from its repository secrets
(`secrets: { EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }} }`), and the gate puts it in
the environment of the step that runs the targets and nowhere else.

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
