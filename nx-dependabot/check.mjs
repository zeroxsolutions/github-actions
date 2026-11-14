#!/usr/bin/env node
// Checks, or with --write rewrites, the block of `.github/dependabot.yml` that leaves to
// `nx migrate` what `nx migrate` manages. Run it from the root of an nx workspace whose
// dependencies are installed, because the list comes from the installed plugins.
//
// `nx migrate` moves nx, every `@nx/*` plugin, and each third-party package a plugin's
// `migrations.json` names under `packageJsonUpdates`, and it rewrites the workspace's config
// and code for the new versions in the same step. A Dependabot bump of one of those packages
// moves the version and skips the rewrite, and one beyond the range the installed plugins
// support breaks them. So:
//
//   nx, @nx/*                      ignored entirely
//   a managed package at ^X.Y.Z    semver-major ignored, X >= 1
//   a managed package at ~X.Y.Z,   semver-major and semver-minor ignored; on 0.x a minor
//     or at ^0.Y.Z                 is a breaking release, as a major is on 1.x
//   a managed package the          ignored entirely; it is on a version the installed plugins
//     workspace declares past        do not support yet, so even its patches wait for the
//     that range                     plugin release that names its line
//
// The block sits between `# nx-managed:start` and `# nx-managed:end` inside the npm entry's
// `ignore:` list, so a repository keeps its own entries outside the markers.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const CONFIG = '.github/dependabot.yml';
const START = '# nx-managed:start';
const END = '# nx-managed:end';
const write = process.argv.includes('--write');
// Runs from any checkout with `gh` signed in, so fixing the block needs no clone of this repository.
const WRITE_COMMAND = [
  "gh api 'repos/zeroxsolutions/github-actions/contents/nx-dependabot/check.mjs?ref=v1' \\",
  "  -H 'Accept: application/vnd.github.raw' | node --input-type=module - --write",
].join('\n');

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));

// [major, minor, patch, isPrerelease]; a prerelease sorts before its release.
const parse = (version) => {
  const match = /^(\d+)\.(\d+)\.(\d+)(-.*)?$/.exec(version);
  return match && [+match[1], +match[2], +match[3], match[4] ? 0 : 1];
};
const compare = (a, b) => {
  for (let i = 0; i < 4; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
};

const plugins = ['nx'];
if (existsSync('node_modules/@nx')) {
  for (const name of readdirSync('node_modules/@nx')) plugins.push(`@nx/${name}`);
}
if (!existsSync('node_modules/nx/package.json')) {
  console.error('::error::node_modules/nx is missing; install the workspace before running this check.');
  process.exit(1);
}

// The range each managed package takes, from the newest update at or below the installed
// plugin's own version: a later entry names a range the installed plugin does not support yet.
const ranges = new Map();
for (const plugin of plugins) {
  const dir = join('node_modules', plugin);
  const manifest = readJson(join(dir, 'package.json'));
  const migrationsPath = manifest['nx-migrations']?.migrations ?? manifest['ng-update']?.migrations;
  if (!migrationsPath || !existsSync(join(dir, migrationsPath))) continue;
  const installed = parse(manifest.version);
  const updates = readJson(join(dir, migrationsPath)).packageJsonUpdates ?? {};
  for (const update of Object.values(updates)) {
    const at = parse(update.version ?? '');
    if (!at || !installed || compare(at, installed) > 0) continue;
    for (const [name, entry] of Object.entries(update.packages ?? {})) {
      if (name === 'nx' || name.startsWith('@nx/') || name.startsWith('@nrwl/')) continue;
      const known = ranges.get(name);
      if (!known || compare(at, known.at) >= 0) ranges.set(name, { at, range: entry.version });
    }
  }
}

// A plugin names packages for setups this workspace may not have, such as a bundler it does
// not use; only those the workspace declares belong in its Dependabot config. Each name keeps
// the specifiers it is declared with, to tell a workspace past the plugin's range.
const declared = new Map();
const declare = (name, specifier) => {
  if (!declared.has(name)) declared.set(name, []);
  if (typeof specifier === 'string') declared.get(name).push(specifier);
};
const tracked = execFileSync('git', ['ls-files', '--', 'package.json', '**/package.json'], { encoding: 'utf8' })
  .split('\n')
  .filter(Boolean);
for (const path of tracked) {
  const manifest = readJson(path);
  for (const field of ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']) {
    for (const [name, specifier] of Object.entries(manifest[field] ?? {})) declare(name, specifier);
  }
}
// A pnpm catalog holds the version a package.json names as `catalog:`.
if (existsSync('pnpm-workspace.yaml')) {
  // A named catalog's own key, such as `expo:` above its entries, carries no version.
  const catalogEntry = /^[ \t]+['"]?(@?[\w./-]+)['"]?[ \t]*:[ \t]*['"]?([^'"#\s]*)/gm;
  for (const match of readFileSync('pnpm-workspace.yaml', 'utf8').matchAll(catalogEntry)) {
    declare(match[1], match[2]);
  }
}

const quote = (name) => (name.startsWith('@') || name.includes('*') ? `'${name}'` : name);
const entries = [
  "# Generated from the installed nx plugins' migrations.json by zeroxsolutions/github-actions",
  '# nx-dependabot; these move through `nx migrate`. Edit outside the markers.',
  '- dependency-name: nx',
  "- dependency-name: '@nx/*'",
];
// The first version a range leaves out, matching the update types ignored below: the next
// major for ^X.Y.Z with X >= 1, the next minor for ~X.Y.Z, ^0.Y.Z or an exact X.Y.Z. A range
// with no upper bound, such as >=X.Y.Z, gives none.
const ceiling = (range) => {
  const lowest = parse(range.replace(/^[\^~=\s]+/, ''));
  if (!lowest || /^[<>]/.test(range.trim())) return null;
  return range.startsWith('^') && lowest[0] >= 1 ? [lowest[0] + 1, 0, 0, 0] : [lowest[0], lowest[1] + 1, 0, 0];
};
// A specifier past the ceiling is one whose lowest version is at or above it; `catalog:`,
// `workspace:` and other protocols name no version and are skipped.
const pastRange = (name, range) => {
  const top = ceiling(range);
  return (
    top !== null &&
    declared.get(name).some((specifier) => {
      const lowest = parse(specifier.replace(/^[\^~=v\s]+/, ''));
      return lowest !== null && compare(lowest, top) >= 0;
    })
  );
};

const managed = [...ranges.keys()].filter((name) => declared.has(name)).sort();
for (const name of managed) {
  const range = ranges.get(name).range;
  if (pastRange(name, range)) {
    entries.push(`- dependency-name: ${quote(name)} # nx: ${range}; declared past it`);
    continue;
  }
  const lowest = parse(range.replace(/^[\^~>=<\s]+/, ''));
  const majorOnly = range.startsWith('^') && lowest && lowest[0] >= 1;
  const types = majorOnly
    ? 'version-update:semver-major'
    : 'version-update:semver-major, version-update:semver-minor';
  entries.push(`- dependency-name: ${quote(name)} # nx: ${range}`, `  update-types: [${types}]`);
}

if (!existsSync(CONFIG)) {
  console.error(`::error::${CONFIG} is missing.`);
  process.exit(1);
}
const lines = readFileSync(CONFIG, 'utf8').split('\n');
const start = lines.findIndex((line) => line.trim() === START);
const end = lines.findIndex((line) => line.trim() === END);
const indent = start >= 0 ? lines[start].match(/^\s*/)[0] : '      ';
const block = entries.map((line) => indent + line);

if (start < 0 || end < start) {
  console.error(`::error file=${CONFIG}::No ${START} ... ${END} block in the npm entry's ignore list.`);
  console.error(`Add the two markers under the npm entry's \`ignore:\`, then run:\n\n${WRITE_COMMAND}\n\nThe block it writes:\n\n${indent}${START}\n${block.join('\n')}\n${indent}${END}`);
  process.exit(1);
}

const current = lines.slice(start + 1, end);
if (current.join('\n') === block.join('\n')) {
  console.log(`${CONFIG}: the nx-managed block matches the installed plugins (${managed.length} packages besides nx).`);
  process.exit(0);
}
if (write) {
  writeFileSync(CONFIG, [...lines.slice(0, start + 1), ...block, ...lines.slice(end)].join('\n'));
  console.log(`${CONFIG}: rewrote the nx-managed block.`);
  process.exit(0);
}
console.error(`::error file=${CONFIG}::The nx-managed block does not match the installed nx plugins.`);
console.error(`Expected, between the markers:\n\n${block.join('\n')}\n`);
console.error(`Rewrite it from the workspace root, with dependencies installed:\n\n${WRITE_COMMAND}`);
process.exit(1);
