# The Playground's own repository (2026-11-08)

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
  compilers it names (the archives stay in Shireworks' files);
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
and the Storybook. isomer's proof becomes the Storybook's alone: the
Playground's CI carries its own copy of the proof's scripts (CI's tools,
copied between the project's repositories as the publishing scripts are).

isomer's own changes:

- examples/MODULE.bazel and Package.swift lose agent_ui and open_router_cli;
- a build's number (MAJOR.MINOR.BUILD) comes from the Storybook's build
  number on the release server, not the Playground's
  (tools/ci/next_version.sh, draft_release.sh);
- release_assets.sh carries the Storybook's builds alone; pages.yml publishes
  the Storybook's site (//web/storybook_web_application:isomer_site in the
  examples) at attilathefun.github.io/isomer/, and the Playground's site is
  the playground repository's own;
- AGENTS.md, README and docs say where the Playground went.

## History

`git filter-repo` on a fresh clone of isomer, keeping the Playground's paths
since it came back into isomer (playground/ from 0.36, examples/playground/
from 0.39) renamed to the new root. Its history from 0.15 to 0.35, when it
was the private AttilaTheFun/playground_isomer (archived), is not joined:
that would publish a private repository's history. isomer's history is left
as it is.

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
  xcode-27 Macs, the web in Chrome; Android on a Shireworks emulator until
  the arm64 compiler runs on GitHub's, an open question), `prerelease` and
  `release` (Alphas, the draft, CI's as isomer's).

Before its first run: New Container Helper makes the repository and its
runners' access (the isomer-jit labels, Shireworks' files and cache); the
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

1. 0.46 published; isomer pins stay as they are. (Done: 0.46.1.)
2. The repository made; the history filtered into it; its module building
   against isomer 0.46.1 in CI. (Made; its first CI, playground#1.)
3. isomer's pull request removing the Playground (and agent_ui) and moving
   the version number to the Storybook's, merged when the Playground's CI is
   green.
4. AgentUI's test module (the Visor session), against isomer 0.46 or later.
5. The Playground's first release, 0.47.N.
