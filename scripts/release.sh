#!/usr/bin/env bash
# release.sh -- cut an edge appliance release in one command (run on the DEVELOPER machine,
# not on a box; needs git, gh (authenticated), jq).
#
#   1. Resolve the backend + frontend release tags (the latest release that actually carries
#      its Windows asset, or the ones you pass).
#   2. Refuse unless the cloud already runs that backend (cloud first, then edges):
#      the backend tag must be <= aws-infra/image-tags.json "laguna".
#   3. Pin them in versions.json, commit, tag this repo vX.Y.Z, push.
#   4. Publish a GitHub Release of this repo with:
#        edge-vX.Y.Z.zip    tracked files at the tag (scripts, Caddyfile, services, alloy, ...);
#                           never env/, certs/ or data -- those are gitignored, so not in git archive
#        manifest.json      every component's tag, download URL and sha256 + the infra pins
#      (+ .sha256 for each). The future laguna-updater reads manifest.json; signing it
#      (minisign, key kept off CI) lands with that updater.
#
# Usage:  scripts/release.sh                                  # latest app releases, bump patch
#         scripts/release.sh --backend v1.1.18 --frontend v1.0.2 --version v1.1.0
#         scripts/release.sh --dry-run                        # resolve + check, change nothing
#
# Env:    AWS_INFRA_DIR  path to the aws-infra checkout (default: ../aws-infra)
set -euo pipefail

OWNER=bperezgo
EDGE_REPO=laguna-escondida-edge
BACKEND_REPO=laguna-escondida-backend
FRONTEND_REPO=laguna-escondida-frontend

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AWS_INFRA_DIR=${AWS_INFRA_DIR:-"$ROOT/../aws-infra"}
VERSIONS="$ROOT/versions.json"

BACKEND="" FRONTEND="" VERSION="" DRY_RUN=0 YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --backend)  BACKEND=$2; shift 2 ;;
    --frontend) FRONTEND=$2; shift 2 ;;
    --version)  VERSION=$2; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --yes|-y)   YES=1; shift ;;
    -h|--help)  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
is_semver() { printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; }
# semver_le A B: A <= B
semver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }
# versions.json is written by PowerShell with a UTF-8 BOM, which jq rejects.
strip_bom() { LC_ALL=C sed $'1s/^\xef\xbb\xbf//' "$1"; }

backend_asset()  { echo "edge-node-windows-amd64-$1.zip"; }   # names match the app repos'
frontend_asset() { echo "next-standalone-windows-$1.zip"; }   # release.yml and fetch-artifacts.ps1

for t in git gh jq; do command -v "$t" >/dev/null || die "$t is not installed"; done
cd "$ROOT"

# true if release $2 of repo $1 has both $3 and $3.sha256
has_asset() {
  local names
  names=$(gh release view "$2" -R "$OWNER/$1" --json assets -q '.assets[].name' 2>/dev/null) || return 1
  printf '%s\n' "$names" | grep -qxF "$3" && printf '%s\n' "$names" | grep -qxF "$3.sha256"
}

# newest published release of repo $1 whose Windows asset (named by function $2) exists.
# A tag whose CI failed has a release with no asset -- skip it rather than pin it.
latest_with_asset() {
  local tag
  for tag in $(gh release list -R "$OWNER/$1" --exclude-drafts --exclude-pre-releases -L 20 \
                 --json tagName -q '.[].tagName' | sort -rV); do
    is_semver "$tag" || continue
    if has_asset "$1" "$tag" "$($2 "$tag")"; then echo "$tag"; return 0; fi
  done
  return 1
}

sha_of() {  # repo tag asset -> sha256 from the release's .sha256 asset
  local sum
  sum=$(gh release download "$2" -R "$OWNER/$1" -p "$3.sha256" -O - | awk '{print tolower($1)}')
  printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' || die "$1 $2: $3.sha256 is not a sha256 checksum"
  echo "$sum"
}

# --- preflight ---------------------------------------------------------------------
step "Preflight"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "release from main (on $(git rev-parse --abbrev-ref HEAD))"
git fetch -q origin --tags
[ "$(git rev-list --count main..origin/main)" = 0 ] || die "main is behind origin/main; pull first"
git diff --quiet HEAD -- versions.json || die "versions.json has uncommitted changes"
UNPUSHED=$(git log --oneline origin/main..main)
echo "  ok"

# --- 1. resolve app tags -----------------------------------------------------------
step "Resolve app releases"
if [ -z "$BACKEND" ]; then
  BACKEND=$(latest_with_asset "$BACKEND_REPO" backend_asset) || die "no $BACKEND_REPO release has a Windows asset"
fi
if [ -z "$FRONTEND" ]; then
  FRONTEND=$(latest_with_asset "$FRONTEND_REPO" frontend_asset) || die "no $FRONTEND_REPO release has a Windows asset"
fi
is_semver "$BACKEND"  || die "backend '$BACKEND' is not a vX.Y.Z tag"
is_semver "$FRONTEND" || die "frontend '$FRONTEND' is not a vX.Y.Z tag"
BACKEND_ZIP=$(backend_asset "$BACKEND");   has_asset "$BACKEND_REPO"  "$BACKEND"  "$BACKEND_ZIP" \
  || die "$BACKEND_REPO $BACKEND has no $BACKEND_ZIP (+ .sha256) -- did its release CI fail?"
FRONTEND_ZIP=$(frontend_asset "$FRONTEND"); has_asset "$FRONTEND_REPO" "$FRONTEND" "$FRONTEND_ZIP" \
  || die "$FRONTEND_REPO $FRONTEND has no $FRONTEND_ZIP (+ .sha256) -- did its release CI fail?"
BACKEND_SHA=$(sha_of "$BACKEND_REPO" "$BACKEND" "$BACKEND_ZIP")
FRONTEND_SHA=$(sha_of "$FRONTEND_REPO" "$FRONTEND" "$FRONTEND_ZIP")
echo "  backend   $BACKEND   $BACKEND_SHA"
echo "  frontend  $FRONTEND   $FRONTEND_SHA"

# --- 2. cloud first ----------------------------------------------------------------
# image-tags.json is what `cdk deploy bryan-dev-services` runs, i.e. the cloud's pinned tag.
# (Once the cloud reports its version over HTTP, check the live value instead.)
step "Cloud-first check"
TAGS_FILE="$AWS_INFRA_DIR/image-tags.json"
[ -f "$TAGS_FILE" ] || die "$TAGS_FILE not found (set AWS_INFRA_DIR)"
CLOUD=$(jq -r '.laguna' "$TAGS_FILE")
is_semver "$CLOUD" || die "$TAGS_FILE: laguna '$CLOUD' is not a vX.Y.Z tag"
semver_le "$BACKEND" "$CLOUD" \
  || die "backend $BACKEND is newer than the cloud ($CLOUD in aws-infra/image-tags.json). Deploy the cloud first, or pass --backend $CLOUD-or-older."
echo "  cloud runs $CLOUD >= $BACKEND"

# --- 3. edge version ---------------------------------------------------------------
LAST=$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
if [ -z "$VERSION" ]; then
  if [ -z "$LAST" ]; then VERSION=v1.0.0
  else
    IFS=. read -r MA MI PA <<EOF
${LAST#v}
EOF
    VERSION="v$MA.$MI.$((PA + 1))"
  fi
fi
is_semver "$VERSION" || die "--version '$VERSION' is not vX.Y.Z"
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && die "tag $VERSION already exists"
if [ -n "$LAST" ] && semver_le "$VERSION" "$LAST"; then die "$VERSION is not newer than $LAST"; fi

OLD_BACKEND=$(strip_bom "$VERSIONS" | jq -r '.artifacts["edge-node"].version')
OLD_FRONTEND=$(strip_bom "$VERSIONS" | jq -r '.artifacts.next.version')
if [ -n "$LAST" ] && [ "$OLD_BACKEND" = "$BACKEND" ] && [ "$OLD_FRONTEND" = "$FRONTEND" ] \
   && git diff --quiet "$LAST" HEAD; then
  die "nothing to release: same app pins and no commits since $LAST"
fi

# --- summary + confirm -------------------------------------------------------------
step "Release $EDGE_REPO $VERSION${LAST:+  (previous: $LAST)}"
echo "  edge-node  $OLD_BACKEND -> $BACKEND"
echo "  next       $OLD_FRONTEND -> $FRONTEND"
if [ -n "$UNPUSHED" ]; then echo "  also pushes these unpushed commits on main:"; printf '%s\n' "$UNPUSHED" | sed 's/^/    /'; fi
if [ "$DRY_RUN" = 1 ]; then echo; echo "dry run: nothing changed."; exit 0; fi
if [ "$YES" != 1 ]; then
  printf '\nCommit, tag, push and publish? [y/N] '; read -r ok
  case "$ok" in y|Y|yes) ;; *) echo "aborted."; exit 1 ;; esac
fi

# --- 4. pin, commit, tag, push -----------------------------------------------------
step "Pin versions.json"
# Keep the BOM and 4-space layout PowerShell wrote, so the diff is just the two pins.
tmp=$(mktemp)
strip_bom "$VERSIONS" \
  | jq --indent 4 --arg b "$BACKEND" --arg f "$FRONTEND" \
       '.artifacts["edge-node"].version = $b | .artifacts.next.version = $f' > "$tmp"
{ printf '\xef\xbb\xbf'; cat "$tmp"; } > "$VERSIONS"; rm -f "$tmp"
if git diff --quiet -- versions.json; then
  echo "  pins unchanged"
else
  git commit -q -m "release: $VERSION (edge-node $BACKEND, next $FRONTEND)" -- versions.json
  echo "  committed $(git rev-parse --short HEAD)"
fi
git tag -a "$VERSION" -m "edge appliance $VERSION: edge-node $BACKEND, next $FRONTEND"
git push -q origin main "refs/tags/$VERSION"
echo "  pushed main + $VERSION"

# --- 5. build + publish the release ------------------------------------------------
step "Publish GitHub Release $VERSION"
OUT=$(mktemp -d)
EDGE_ZIP="edge-$VERSION.zip"
git archive --format=zip -o "$OUT/$EDGE_ZIP" "$VERSION"
EDGE_SHA=$(shasum -a 256 "$OUT/$EDGE_ZIP" | awk '{print $1}')
url() { echo "https://github.com/$OWNER/$1/releases/download/$2/$3"; }

strip_bom "$VERSIONS" | jq --indent 2 \
  --arg version "$VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg commit "$(git rev-parse "$VERSION^{commit}")" \
  --arg edge_url "$(url "$EDGE_REPO" "$VERSION" "$EDGE_ZIP")" --arg edge_sha "$EDGE_SHA" \
  --arg b "$BACKEND" --arg b_url "$(url "$BACKEND_REPO" "$BACKEND" "$BACKEND_ZIP")" --arg b_sha "$BACKEND_SHA" \
  --arg f "$FRONTEND" --arg f_url "$(url "$FRONTEND_REPO" "$FRONTEND" "$FRONTEND_ZIP")" --arg f_sha "$FRONTEND_SHA" \
  '{
     appliance_version: $version,
     published_at: $at,
     git_commit: $commit,
     components: {
       edge:        { tag: $version, url: $edge_url, sha256: $edge_sha },
       "edge-node": { repo: .artifacts["edge-node"].repo, tag: $b, url: $b_url, sha256: $b_sha },
       next:        { repo: .artifacts.next.repo,         tag: $f, url: $f_url, sha256: $f_sha }
     },
     infra: { winsw, caddy, alloy, node, postgres }
   }' > "$OUT/manifest.json"
(cd "$OUT" && shasum -a 256 "$EDGE_ZIP" > "$EDGE_ZIP.sha256" && shasum -a 256 manifest.json > manifest.json.sha256)

NOTES="Edge appliance $VERSION

| component | version |
|---|---|
| edge-node ($BACKEND_REPO) | $BACKEND |
| next ($FRONTEND_REPO) | $FRONTEND |
| cloud at release time | $CLOUD |"
if ! gh release create "$VERSION" -R "$OWNER/$EDGE_REPO" --verify-tag --title "$VERSION" \
       --notes "$NOTES" --generate-notes \
       "$OUT/$EDGE_ZIP" "$OUT/$EDGE_ZIP.sha256" "$OUT/manifest.json" "$OUT/manifest.json.sha256"; then
  die "tag $VERSION is pushed but the release failed. Assets are in $OUT; retry with:
  gh release create $VERSION -R $OWNER/$EDGE_REPO --verify-tag --title $VERSION --generate-notes $OUT/*"
fi
rm -rf "$OUT"
printf '\n\033[32mReleased %s\033[0m  https://github.com/%s/%s/releases/tag/%s\n' "$VERSION" "$OWNER" "$EDGE_REPO" "$VERSION"
echo "Boxes are offered new app releases in the POS (scripts/updater.ps1). For scripts, Caddyfile or"
echo "services changes: git pull on each box, then scripts\\install.ps1."
