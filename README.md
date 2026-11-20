# Slack Desktop for Linux aarch64 — Flatpak repo

Slack Desktop running natively on **aarch64 (arm64)** Linux, from a Flatpak repo
hosted on GitHub Pages and rebuilt by GitHub Actions every time Slack ships a release.

Fork of [Josholith/slack-linux-arm64-flatpak](https://github.com/Josholith/slack-linux-arm64-flatpak)
(MIT). It keeps the upstream build and adds two things:

- **No Slack binaries are redistributed.** The flatpak uses
  [extra-data](https://docs.flatpak.org/en/latest/module-sources.html#extra-data), the same way
  Flathub's `com.slack.Slack` does. The repo only contains an arm64 Electron runtime,
  native modules built from MIT-licensed npm sources, and no-op stubs. When you install or
  update, flatpak downloads Slack's official `.deb` and Slack's arm64
  `slack-desktop-utils` prebuild **from Slack's servers**, checks their SHA-256 hashes, and
  assembles the app on your machine (`manifest/apply_extra`).
- **Automatic updates.** `.github/workflows/build.yml` checks Slack's release API every
  4 hours. For a new version it builds on a native arm64 runner, adds the result to the
  signed OSTree repo on GitHub Pages, and creates a GitHub release.

> Unofficial. Not affiliated with or supported by Slack.

## Install

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --user --if-not-exists slack-arm64 https://vintoware.github.io/slack-arm64-flatpak/slack-arm64.flatpakrepo
flatpak install --user slack-arm64 com.slack.Slack
```

New Slack versions arrive with a regular `flatpak update`. Flathub provides the
`org.gnome.Platform` runtime. The repo is signed with the key in `slack-arm64-flatpak.gpg.asc`
(fingerprint `53642E94B0CC55BAB30D88A2347FA5BF6B767DC1`).

## How it works

```
official Slack .deb (x86_64)  ──►  native/01..04   detect Slack's Electron + module versions,
                                                   build/fetch arm64 native modules, and
                                                   verify a full arm64 tree (build-time only)
                                   native/05       package ONLY the redistributable parts:
                                                   arm64 Electron + open-source .node + stubs
                                                   ─► slack-overlay-<VER>-arm64.tar.xz
                                                   ─► extra-data.env (Slack URLs + sha256 + size)
manifest/ (org.gnome.Platform:51)  ──►  flatpak-builder: /app = overlay, launcher, desktop file,
                                        icon, metainfo; extra-data = Slack .deb + SDU prebuild
ci/publish-repo.sh                 ──►  signed OSTree repo + .flatpakrepo/.flatpakref on Pages

on the user's machine, at install/update time (flatpak, no network in the hook):
  download slack.deb + slack-desktop-utils.tar.gz from Slack  ──►  apply_extra:
  resources/ from the .deb → /app/extra/resources (symlinked from /app/slack/resources),
  overlay arm64 .node files + Slack's arm64 slack-desktop-utils, refuse if any x86-64 remains
```

All build stages run in containers (Docker, or podman locally), so the host stays clean.

### Native modules (aarch64)
| Module | Source |
|--------|--------|
| `native-keymap` | built from public npm `native-keymap` via node-gyp |
| `electron-native-auth` | built from public npm `electron-native-auth` |
| `file-handler-info` | built from public npm `file-handler-info` |
| `@tinyspeck/slack-desktop-utils` | arm64 prebuild from Slack's S3 |
| `cf-prefs`, `registry-js`, `windows-focus-assist`, `macos-notification-state` | arm64 N-API stub (Linux no-ops) |

### Base runtime: `org.gnome.Platform:51`
Slack's Electron links only against libraries that `org.gnome.Platform` already
ships, so the app is a **pure file copy — zero build modules**. Flathub serves
`org.gnome.Platform` for aarch64 (current branch **51**). See **AGENTS.md** for the
full list of linked libraries and the reasoning.


## CI / repo hosting

| Piece | Where |
|---|---|
| Release check | Slack's API: `https://slack.com/api/desktop.latestRelease?arch=x64&variant=deb` |
| "Already built?" | a GitHub release tagged `v<slack version>` exists |
| Build runner | `ubuntu-24.04-arm` (native arm64, so no QEMU) |
| Flatpak repo | GitHub Pages (`actions/deploy-pages`); `ci/publish-repo.sh` mirrors the published commit back first, so updates ship as small static deltas. History is pruned to one parent |
| Signing | `GPG_PRIVATE_KEY` repository secret (no passphrase). The public key is embedded in the `.flatpakrepo` and `.flatpakref` files |
| Manual run | Actions → *Build and publish* → *Run workflow* (optional `version`, `force`) |

If Slack hasn't published the arm64 `slack-desktop-utils` prebuild for a new release
yet, stage 04 fails. No release gets created, so the next scheduled run tries again.

## How this differs from Slacky

[Slacky](https://github.com/andirsun/Slacky) also exists to give arm64 Linux a usable
Slack, and it's a fine project — but it takes the **opposite** approach.

| | **Slacky** | **this repo** |
|---|---|---|
| **What it is** | a from-scratch Electron **wrapper** of Slack's **web app** | a **repack of the official** Slack desktop app |
| **App code** | its own TypeScript app that `loadURL`s `app.slack.com` | Slack's own, unmodified `app.asar` |
| **Electron** | an independent, current build (Electron 42) | Slack's **exact** shipped Electron version |
| **Native modules** | none to manage (a generic Electron app) | Slack's **proprietary** `.node` modules, rebuilt/fetched for arm64 |
| **Runs** | Slack's **web client**, over the network | the **native desktop** client (offline-capable) |
| **Arm64 method** | build a normal Electron app for arm64 | swap in arm64 Electron + arm64 native modules |
| **Packaging** | AppImage / deb / rpm (electron-builder) | a **Flatpak** repo (Slack downloaded as extra-data) |
| **How it builds** | CircleCI on a native arm64 runner | Docker (native on arm64, or cross via QEMU on x86_64) |

The practical consequences of that split:

- **Fidelity.** This repo is the *same native desktop client* x86_64 users get —
  native features and offline use included. Slacky runs Slack's *web* client in a
  fresh Electron shell, so it's subject to Slack's web-side changes and needs
  user-agent tweaks to avoid "unsupported browser" notices.
- **The hard part lives here.** Slacky sidesteps the genuinely difficult part of an
  arm64 repack — matching Slack's exact Electron version and producing aarch64 copies
  of its **proprietary** native modules (e.g. `@tinyspeck/slack-desktop-utils`) —
  simply by not using Slack's app. Producing those is the core of what this repo does.
- **Maintenance model.** Slacky is a living client: it re-implements shell features
  (workspace switcher, system theme, huddle windows, SSO, screen share) and tracks its
  own releases. This repo is a deliberately thin repack — when Slack ships a new
  version we swap the arm64 bits again; we don't add features.

**In short:** Slacky is "Slack's web app in a new shell"; this repo is "the official
Slack desktop app, rebuilt for arm64." Choose the exact native client (this), or a
maintained wrapper (Slacky).

## Requirements (build host)
- **Docker** on any host. An **aarch64** host (Raspberry Pi 5, Graviton, aarch64
  VPS) is **recommended** and builds natively (fastest); an **x86_64** host is
  **fully supported** too — it cross-compiles aarch64 via QEMU
  (`BUILD_PLATFORM=linux/arm64`) and just takes a little longer.
- **Unprivileged user namespaces** enabled (flatpak-builder's bubblewrap sandbox):
  on Debian/Ubuntu `sysctl kernel.unprivileged_userns_clone=1` + the container
  seccomp/caps in `FLATPAK_DOCKER_FLAGS`.
- **Outbound network**: Slack CDN, `github.com` (Electron),
  `slack-desktop-native-prebuilds.s3.amazonaws.com`, `npmjs.com`, `dl.flathub.org`.
- ~10 GB free disk.

## Quick start
```sh
# SLACK_VERSION defaults to Slack's latest release (from Slack's API).
./build.sh                          # docker, or podman if docker is absent
SLACK_VERSION=4.53.287 ./build.sh   # a specific version
```

Outputs in `dist/`:

| File | What |
|------|------|
| `com.slack.Slack.aarch64.flatpak` | bundle; installing it downloads Slack via extra-data |
| `build-inputs.json` | versions + SHA-256 (reproducibility record) |
| `extra-data.env` | the Slack package URLs/hashes the build declares |

`.fp/repo` holds the OSTree repo that `ci/publish-repo.sh` folds into the published one.

Install on any machine with Flatpak:
```sh
flatpak install dist/com.slack.Slack.aarch64.flatpak
flatpak run com.slack.Slack
```

## Updating to a new Slack version
CI does this automatically. By hand: `SLACK_VERSION=<ver> ./build.sh`. The Electron,
native-module, napi and S3-prebuild versions are **auto-detected** from the package.
A local `SLACK_SOURCE_FILE` must be byte-identical to the file on Slack's CDN, because
users' machines download it from there and check its hash.

## Configuration
See `.env.example`. Key knobs:

| Variable | Meaning |
|----------|---------|
| `SLACK_SOURCE_FILE` / `SLACK_SOURCE_URL` | the official package to build from |
| `SLACK_APP_ID` | `com.slack.Slack` (default) or `com.slack.Slack.aarch64` |
| `FLATPAK_RUNTIME` / `FLATPAK_RUNTIME_VERSION` | base (default `org.gnome.Platform/51`) |
| `FLATPAK_SDK` | matching build base (default `org.gnome.Sdk`) |
| `NATIVE_BASE_IMAGE` / `FLATPAK_BASE_IMAGE` | pinned build images (`node:24.22.2-trixie`, `debian:13.7`) |

## Layout
```
AGENTS.md                 # implementation rationale + gotchas (read before modifying)
build.sh                  # host orchestrator (drives Docker)
build-flatpak.sh          # flatpak-builder driver (runs in the flatpak image)
Dockerfile.native         # node + toolchain + X11/xkbfile headers
Dockerfile.flatpak        # flatpak + flatpak-builder
.env.example              # all knobs
native/                   # 01-fetch → 02-detect → 03-electron → 04-native → 05-assemble (+ stubs/)
manifest/                 # com.slack.Slack.json, slack-install.sh, apply_extra, metainfo.xml
ci/publish-repo.sh        # fold a build into the Pages-hosted OSTree repo + site files
.github/workflows/        # scheduled release check, build, publish
```

## Known limitations
- **Screen share** (Slack "Share Screen") depends on the Wayland/X11 screencast
  portal — the least reliable sandboxed feature. Audio/video calls work.
- **Tray** needs a StatusNotifierWatcher (GNOME "App Indicator" ext, KDE, Xfce…).
- Building the Flatpak in Docker needs unprivileged user namespaces.

## Troubleshooting
- `could not obtain the Slack package` → check `SLACK_VERSION` matches a real
  release (Slack download page or the Arch AUR `slack-desktop` PKGBUILD), or pin a
  local file via `SLACK_SOURCE_FILE`.
- Re-downloading the Slack package on every build → it's cached in the repo's
  `.cache/` dir (git-ignored), keyed by version; a second build for the same
  version reuses it. Delete `.cache/` to force a fresh download.
- `org.gnome.Platform … not found` for aarch64 → confirm
  `dl.flathub.org` is reachable; Flathub serves the aarch64 runtime automatically.
- flatpak-builder hangs in Docker → enable user namespaces + `FLATPAK_DOCKER_FLAGS`.

## Acknowledgments

This project stands on the shoulders of a couple of open efforts:

- **`hamza72x/slack-linux-arm64`** — <https://github.com/hamza72x/slack-linux-arm64>.
  This repo was originally intended to fork from that project, but so much was
  reworked from first principles that the result is a fresh, standalone
  implementation rather than a fork. It is best described as a **spiritual
  ancestor and guiding inspiration** for this work, not a direct lineage.
- **The Arch AUR `slack-desktop` PKGBUILD** —
  <https://aur.archlinux.org/packages/slack-desktop>. Credit for the working
  Slack CDN download URL (`downloads.slack-edge.com`) that the fetch stage uses.

## Provenance

For provenance — and to encourage the use of open-weights AI — this repository
(design, Docker pipeline, Flatpak manifest, and build scripts) was produced
almost entirely by an **open-weights AI model running locally**: **Qwen3.8 27B**
with a **250k-token context window**, driven by **Cline** (<https://cline.bot/>)
as the coding-agent harness. None of this is required to use or contribute to
the code; it is noted here for provenance and to promote awareness of
open-weights models.