# Contributing to the OpenLLM registry

Thanks for wanting to improve an OpenLLM plugin or setup target!

## How this repo works

`registry` is a **read-only mirror**. Every `plugin/<slug>` and
`setup/<slug>` directory here is regenerated from the
[openllm](https://github.com/openllmsh/openllm) monorepo
(`packages/registry/<area>/<slug>`) on each release and force-pushed —
nothing merges here directly.

That said, **PRs against this repo are welcome**: they're the easiest way to
propose a change against the exact content the gateway ships. A maintainer
ingests your diff upstream with your authorship preserved (`Co-authored-by`),
and it lands back here on the next release.

## What a bundle looks like

Each `<area>/<slug>` directory is a self-contained bundle:

- `PLUGIN.md` / `SETUP.md` — the manifest. YAML frontmatter (`version`,
  `name`, `description`, …) + the human-readable body the gateway renders.
- `install.sh` — the mode-aware installer (`?mode=uninstall|state`), POSIX
  shell. It must stay idempotent and non-destructive: merge into user config,
  never clobber it.
- Optional extras (e.g. `hooks/` scripts) shipped verbatim in the bundle.

## Ground rules

1. **Bump the version** in the manifest frontmatter with any content change —
   bundles are content-addressed (`<area>/<slug>@<version>` + a committed
   sha256); new bytes under an old version can never publish.
2. **Keep installers safe**: no `rm -rf` outside the bundle's own install
   dir, no overwriting user settings without a merge path, fail loudly rather
   than half-install.
3. **No secrets in bundles** — API keys and gateway URLs are injected at
   install time (`__GATEWAY_URL__` / `__API_KEY__` placeholders), never
   committed.
4. **Test the round trip**: `install → state → uninstall` should leave a
   machine as it started.
5. **Don't compute drift in the bundle**: `install.sh -s` prints one JSON
   line `{"installed":bool,"version":string|null}` and nothing more. The
   gateway wrapper injects the `diverged` flag itself by comparing the
   install-time bundle-sha256 stamp (`~/.openllm/installed/<area>-<slug>`)
   against the current digest — so bumping your bundle version automatically
   flips existing installs to "diverged" until they reinstall.
6. **Back up before the first write**: call the wrapper-injected
   `backup_once <file> "<area>/<slug>"` before your first-ever modification
   of a user config file (guard with `if type backup_once >/dev/null 2>&1`).
   Backups are write-once under `~/.openllm/backups/` and kept on uninstall.

## Proposing a change

- **Small fix** (typo, copy, a bug in an `install.sh`): open a PR here — a
  maintainer carries it upstream.
- **New bundle or behavioral change**: open an issue or PR on
  [openllmsh/openllm](https://github.com/openllmsh/openllm) directly
  against `packages/registry/<area>/<slug>` — that's the source of truth and
  where CI (packing, digest, version gates) runs.

## Releases

Bundles publish as GitHub releases on this repo
(`<area>/<slug>@<version>` → `bundle.tar.gz` + `.sha256`), and the gateway
verifies every download against the digest committed in the monorepo. There's
no way to ship a bundle that skips review upstream.
