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

## Environments belong to the caller

`nx-deploy` declares its environment from an input, and that environment resolves
against the **calling** repository - its variables, its secrets, its protection
rules. Verified by experiment, because the GitHub documentation does not state
it plainly and at least one published summary of that documentation states the
opposite.

The consequence worth keeping: **this repository holds no product's credentials
and cannot**, even by accident. A protected environment name in the caller pauses
the deploy job there for a reviewer.

## A private package scope

`pnpm install` runs inside the setup action, so a lockfile naming a package the
public registry does not serve fails there, before any target runs. Both setup
actions take an `npm-token` and write it to a runner-local `.npmrc`; all four
workflows read `secrets.NPM_TOKEN` and pass it down. A caller that does not
forward its secrets resolves that to an empty string, the step is skipped, and a
workspace with only public dependencies never notices.

A caller with a private dependency therefore needs `secrets: inherit`, including
on a gate - a called workflow gets an empty `secrets` context otherwise, and the
failure lands on `pnpm install` rather than anywhere that names a credential.

The token is the caller's, the same way an environment's secrets are: this
repository names it and never holds it.

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
