#!/usr/bin/env bash
#
# publish-repo.sh — fold a fresh build (.fp/repo from build.sh) into the published
# Flatpak repo and lay out the static site for GitHub Pages in ./site:
#
#   site/repo/                         OSTree repo (signed summary, static deltas)
#   site/<REMOTE_NAME>.flatpakrepo     `flatpak remote-add` file (embeds the GPG key)
#   site/<APP_ID>.flatpakref           one-click install file
#   site/index.html                    install instructions
#
# Pages deployments replace the whole site, so the currently published commit is
# mirrored back first: the new commit gets it as parent, and users get a small
# static delta instead of a full download. History is pruned to stay well under the
# Pages size limit.
#
# Runs in the builder image (flatpak, ostree, gnupg, curl).
#
# Env:
#   SITE_URL         https://<owner>.github.io/<repo>   (required)
#   GPG_PRIVATE_KEY  ASCII-armored signing key, no passphrase (required)
#   SLACK_VERSION    for the commit subject (required)
#   PROJECT_URL      project homepage (default: https://github.com/$GITHUB_REPOSITORY)
#
set -euo pipefail

: "${SITE_URL:?SITE_URL must be set}"
: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY must be set}"
: "${SLACK_VERSION:?SLACK_VERSION must be set}"
: "${SLACK_APP_ID:=com.slack.Slack}"
: "${FLATPAK_ARCH:=aarch64}"
: "${FLATPAK_BRANCH:=master}"
: "${REMOTE_NAME:=slack-arm64}"
: "${SRC_REPO:=.fp/repo}"
: "${SITE_DIR:=site}"
: "${PROJECT_URL:=https://github.com/${GITHUB_REPOSITORY:-vintoware/slack-arm64-flatpak}}"
SITE_URL="${SITE_URL%/}"
REF="app/$SLACK_APP_ID/$FLATPAK_ARCH/$FLATPAK_BRANCH"
TITLE="Slack for Linux arm64 (unofficial)"

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

[ -d "$SRC_REPO" ] || { echo "no build repo at $SRC_REPO (run ./build.sh first)" >&2; exit 1; }

export GNUPGHOME; GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
KEY="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
[ -n "$KEY" ] || { echo "GPG_PRIVATE_KEY did not contain a secret key" >&2; exit 1; }
GPG_ARGS=(--gpg-sign="$KEY" --gpg-homedir="$GNUPGHOME")
echo "Signing key: $KEY"

rm -rf "$SITE_DIR"
mkdir -p "$SITE_DIR"
REPO="$SITE_DIR/repo"
ostree init --mode=archive-z2 --repo="$REPO"

log "Restoring the published commit from $SITE_URL/repo"
if curl -fsI "$SITE_URL/repo/config" >/dev/null 2>&1; then
  # Our own previous output; signature checks happen on the users' side.
  ostree remote add --repo="$REPO" --no-gpg-verify published "$SITE_URL/repo"
  if ostree pull --repo="$REPO" --mirror published "$REF"; then
    echo "previous commit: $(ostree rev-parse --repo="$REPO" "$REF")"
  else
    echo "::warning::could not mirror the published commit; publishing without history (no delta)"
  fi
  ostree remote delete --repo="$REPO" published
else
  echo "nothing published yet; starting a new repo"
fi

log "Committing $REF (Slack $SLACK_VERSION)"
flatpak build-commit-from "${GPG_ARGS[@]}" --src-repo="$SRC_REPO" \
  --subject="Slack $SLACK_VERSION" "$REPO" "$REF"

log "Updating summary, appstream, static deltas; pruning history"
flatpak build-update-repo "${GPG_ARGS[@]}" \
  --title="$TITLE" --default-branch="$FLATPAK_BRANCH" \
  --generate-static-deltas --prune --prune-depth=1 "$REPO"
flatpak repo "$REPO" | head -n 20 || true

log "Writing site files"
GPG_B64="$(gpg --batch --export "$KEY" | base64 -w0)"

cat > "$SITE_DIR/$REMOTE_NAME.flatpakrepo" <<EOF
[Flatpak Repo]
Title=$TITLE
Url=$SITE_URL/repo/
Homepage=$PROJECT_URL
Comment=Unofficial aarch64 build of Slack Desktop; Slack itself is downloaded from Slack at install time
DefaultBranch=$FLATPAK_BRANCH
GPGKey=$GPG_B64
EOF

cat > "$SITE_DIR/$SLACK_APP_ID.flatpakref" <<EOF
[Flatpak Ref]
Title=Slack (arm64, unofficial)
Name=$SLACK_APP_ID
Branch=$FLATPAK_BRANCH
Url=$SITE_URL/repo/
SuggestRemoteName=$REMOTE_NAME
Homepage=$PROJECT_URL
IsRuntime=false
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
GPGKey=$GPG_B64
EOF

cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Slack arm64 Flatpak</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; color: #1d1d1f; background: #fff; }
  pre { background: #f2f2f4; padding: .75rem 1rem; overflow-x: auto; border-radius: 6px; }
  @media (prefers-color-scheme: dark) { body { color: #e8e8ea; background: #161618; } pre { background: #242428; } a { color: #8ab4ff; } }
</style>
<h1>Slack for Linux arm64 — Flatpak repo</h1>
<p>Unofficial aarch64 build of Slack Desktop (currently <strong>$SLACK_VERSION</strong>).
The repo ships only an arm64 Electron runtime and open-source native modules;
Slack's official package is downloaded from Slack when you install or update.
Not affiliated with Slack.</p>
<h2>Install</h2>
<pre>flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --user --if-not-exists $REMOTE_NAME $SITE_URL/$REMOTE_NAME.flatpakrepo
flatpak install --user $REMOTE_NAME $SLACK_APP_ID</pre>
<p>Updates arrive with <code>flatpak update</code>. Or open the
<a href="$SLACK_APP_ID.flatpakref">.flatpakref</a> in your software center.</p>
<p><a href="$PROJECT_URL">Source and build scripts</a></p>
</html>
EOF

du -sh "$REPO"
echo "Site ready in $SITE_DIR"
