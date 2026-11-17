#!/bin/bash
# Publish a finished build's .sif to GitHub Container Registry (ghcr.io) as
# an ORAS artifact: oras://ghcr.io/<GHCR_NAMESPACE>/<GHCR_PREFIX><name>:<VERSION_TAG>
#
# Usage: ./push.sh [--yes] [--force_ghcr_overwrite] builds/<NAME>/<VERSION_TAG>
#
#   --yes                   push without asking (required when stdin is not a terminal)
#   --force_ghcr_overwrite  push even if that tag already exists on ghcr.io
#
# Independent of deploy.sh; the build directory is only read. Run on a login
# node after logging in once with:
#   apptainer registry login --username <github user> oras://ghcr.io
# (token needs write:packages). New packages are private on ghcr.io until
# made public in the package's settings on GitHub; that can't be done by API.
#
# This file is identical in ../custom_containeR and ../containerPy (each
# repo's site.sh sets GHCR_NAMESPACE/GHCR_PREFIX); change both together.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '5,8s/^# \{0,1\}//p' "$0" >&2; exit "${1:-1}"; }

YES=0 OVERWRITE=0 BUILD=""
while (( $# )); do
    case "$1" in
        -y|--yes)               YES=1 ;;
        --force_ghcr_overwrite) OVERWRITE=1 ;;
        -h|--help)              usage 0 ;;
        -*)                     echo "ERROR: unknown option $1" >&2; usage ;;
        *)                      [[ -z "$BUILD" ]] || usage; BUILD="$1" ;;
    esac
    shift
done
[[ -n "$BUILD" ]] || usage
source "$SCRIPT_DIR/site.sh"
[[ -n "${GHCR_NAMESPACE:-}" ]] || die "GHCR_NAMESPACE not set in site.sh"

GHCR_HOST="ghcr.io"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

### --- The build must be complete and intact ---
OUT_DIR="$(cd "$BUILD" 2>/dev/null && pwd)" || die "build dir not found: $BUILD"
PROV="$OUT_DIR/provenance"
DEF=$(find "$OUT_DIR" -maxdepth 1 -name '*.def')
[[ $(wc -l <<<"$DEF") -eq 1 && -f "$DEF" ]] || die "expected exactly one .def in $OUT_DIR"
SIF="${DEF%.def}.sif"
[[ -f "$SIF" ]] || die "no .sif in $OUT_DIR; the build did not finish"
for f in build_info.txt sif.sha256; do
    [[ -f "$PROV/$f" ]] || die "missing provenance/$f; the build did not finish"
done
echo "Verifying $(basename "$SIF") checksum..." >&2
(cd "$OUT_DIR" && sha256sum --quiet -c provenance/sif.sha256) || die "checksum mismatch for $SIF"

info() { awk -v k="$1" '$1 == k {print $2; exit}' "$PROV/build_info.txt"; }
NAME=$(info name)
TAG=$(info version_tag)
[[ -n "$NAME" && -n "$TAG" ]] || die "could not read name/version_tag from provenance/build_info.txt"

# OCI repository names must be lowercase; tags have their own charset rule.
REPO="${GHCR_NAMESPACE,,}/${GHCR_PREFIX:-}${NAME,,}"
[[ "$REPO" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] \
    || die "'$REPO' is not a valid OCI repository name"
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "'$TAG' is not a valid OCI tag"
REF="oras://$GHCR_HOST/$REPO:$TAG"

### --- Never overwrite a published tag (unless asked) ---
# 0 = tag exists, 1 = it doesn't, 2 = couldn't tell. "Couldn't tell" refuses
# the push rather than risk replacing a tag. The stored credential is passed
# to curl on stdin (-K -), so it never appears in the process list.
tag_exists() {
    local basic bearer code
    basic=$(jq -er --arg h "$GHCR_HOST" '.auths[$h].auth // empty' "$DOCKER_CONFIG_FILE" 2>/dev/null) || {
        echo "ERROR: no stored credentials for $GHCR_HOST in $DOCKER_CONFIG_FILE; run: apptainer registry login --username <user> oras://$GHCR_HOST" >&2
        return 2
    }
    bearer=$(printf 'header = "Authorization: Basic %s"\n' "$basic" \
        | curl -sS -f -K - "https://$GHCR_HOST/token?service=$GHCR_HOST&scope=repository:$REPO:pull" \
        | jq -er '.token // empty') || {
        echo "ERROR: could not get a registry token from $GHCR_HOST (bad/expired credentials or network?)" >&2
        return 2
    }
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$bearer" \
        | curl -sS -o /dev/null -w '%{http_code}' -I -K - \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "https://$GHCR_HOST/v2/$REPO/manifests/$TAG") || code=000
    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   echo "ERROR: unexpected HTTP $code checking $REPO:$TAG on $GHCR_HOST" >&2; return 2 ;;
    esac
}

rc=0; tag_exists || rc=$?
(( rc != 2 )) || die "could not verify whether $REF already exists; not pushing"
if (( rc == 0 )); then
    (( OVERWRITE )) || die "$REF already exists; published tags are not replaced (pass --force_ghcr_overwrite to replace it)"
    echo "WARNING: $REF already exists and will be REPLACED (--force_ghcr_overwrite)" >&2
fi

cat >&2 <<EOF

Push $OUT_DIR
  image   $(basename "$SIF") ($(du -h "$SIF" | cut -f1))
  to      $REF

EOF
if (( ! YES )); then
    [[ -t 0 ]] || die "not a terminal; re-run with --yes"
    read -r -p "Push? [y/N]: " ans
    [[ "$ans" =~ ^[Yy] ]] || { echo "Not pushed." >&2; exit 0; }
fi

### --- Push, then confirm the registry has it ---
command -v apptainer >/dev/null 2>&1 || module load apptainer
apptainer push "$SIF" "$REF" || die "apptainer push failed for $REF"
rc=0; tag_exists || rc=$?
(( rc == 0 )) || die "push reported success but $REPO:$TAG is not visible on $GHCR_HOST"

mkdir -p "$SCRIPT_DIR/logs"
printf '%s|%s|%s|%s|%s\n' "$(date -Is)" "$USER" "$REF" "$(awk '{print $1}' "$PROV/sif.sha256")" "$OUT_DIR" \
    >> "$SCRIPT_DIR/logs/push.log"

cat >&2 <<EOF

Pushed $REF
Pull with:
  apptainer pull $(basename "$SIF") $REF
(New packages are private until made public at
 https://github.com/users/$GHCR_NAMESPACE/packages/container/${GHCR_PREFIX:-}${NAME,,}/settings)
EOF
