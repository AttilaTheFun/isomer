# The Playground's own repository (plan, 2026-11-08)

The owner's decision: the Playground leaves isomer for a new public
repository, AttilaTheFun/playground, an application on Isomer and AgentUI as
Visor is. isomer then depends on no AgentUI; AgentUI depends on isomer for its
UI tests (headless in Linux containers, headful where a GUI is needed).

    isomer  ◀── agent_ui (tests only) ◀── playground ──▶ isomer
                                    ◀── visor ──────▶ isomer

Releases go in that order: isomer, then agent_ui, then the Playground and
Visor.

## What moves

To AttilaTheFun/playground, at its root:

- examples/playground/**: the iPhone, Mac, web and Android apps, the splash
  page, the compilers' build scripts (tools/playground_toolchain,
  tools/browser_toolchain), the canned projects (shared/sample_sources), its
  docs (AGENTS.md, docs/) and tests (templates, e2e);
- tools/ci/stage_playground_compilers.sh, and the SHA-256s of the staged
  compilers it names (the archives stay in OS Server's files);
- the Playground's half of the CI: its targets in build.yml's container build,
  its Alphas (com.LoganShire.IsomerPlayground, unchanged), its projects in the
  proof (2048 and the Pokédex built on each device), its builds among a
  release's assets, the web Playground's site.

A module of its own (MODULE.bazel `playground`), taking isomer from the
project's registry by version (a commit between releases) and AgentUI,
OpenRouterKit and the rest through its Package.swift, as examples/MODULE.bazel
does today (that block is what it starts from).

## What stays in isomer

What is framework stays: wasm_sdk_bundle, hot_swift_ui, the hot bridge,
WasmView, AppHostViews, hot_host.js, site_imports_test, assemble_directory,
tools/proof (the proof's machinery, which the Playground's CI runs at its
isomer version: `bazel run @isomer//tools/proof`), and the Storybook. isomer's
proof becomes the Storybook's alone.

isomer's own changes:

- examples/MODULE.bazel and Package.swift lose agent_ui and open_router_cli;
- a build's number (MAJOR.MINOR.BUILD) comes from the Storybook's build
  number on the release server, not the Playground's
  (tools/ci/next_version.sh, draft_release.sh);
- release_assets.sh carries the Storybook's builds alone; pages.yml publishes
  the Storybook's site;
- AGENTS.md, README and docs say where the Playground went.

## History

`git filter-repo` on a fresh clone of isomer, keeping the Playground's paths
through their moves and renamed to the new root: examples/playground (since
0.39), playground (0.36 to 0.39) and examples/*/playground_* (before 0.15).
Its history between 0.15 and 0.35, when it was AttilaTheFun/playground_isomer
(archived), is merged in as the first parent of the first moved commit, so
`git log` follows it back. isomer's history is left as it is.

## Versions

The Playground's apps keep their bundle identifier, so their versions can't
go backwards (TestFlight, Applications): the Playground continues isomer's
numbering at the split (0.47.0, its first release's minor) and goes its own
way after, MAJOR.MINOR.BUILD as isomer's.

## CI

As isomer's, under the owner's policy (AttilaTheFun/reviews' CI_POLICY.md):

- `container` on every pull request and `populate` on main, in the
  self-hosted Linux containers (12 GB, as isomer's: the Android desugar);
  the headless tests there;
- by hand: `verify` (the tests needing a GUI, on GitHub's runners), the proof
  (the projects built on each device: the iPhone and the Mac on GitHub's
  xcode-27 Macs, the web in Chrome; Android on an OS Server emulator until
  the arm64 compiler runs on GitHub's, an open question), `prerelease` and
  `release` (Alphas, the draft, CI's as isomer's).

Before its first run: New Container Helper makes the repository and its
runners' access (the isomer-jit labels, OS Server's files and cache); the
Applications session lets the repository publish
com.LoganShire.IsomerPlayground (Applications Server's OIDC rules); the
Reviews session lists it for proofs and releases.

## AgentUI's tests (the Visor session's)

AgentUI gains a test module of its own (Bazel, beside its Package.swift):
small apps over AgentView and the transcript views, built headless
(--@isomer//headless) and driven with IsomerHeadless in its CI's Linux
container; the headful runs that make a release's proof on GitHub's runners.
isomer by version, from the registry.

## Order

1. 0.46 published; isomer pins stay as they are.
2. The repository made; the history filtered into it; its module building
   against isomer 0.46 in CI.
3. isomer's pull request removing the Playground (and agent_ui) and moving
   the version number to the Storybook's, merged when the Playground's CI is
   green.
4. AgentUI's test module (the Visor session), against isomer 0.46 or later.
5. The Playground's first release, 0.47.N.
