#!/bin/bash
# Generate a pinned Apptainer .def for a conda/Python image from config.sh +
# packages.txt.
#
# Usage: ./generate_def.sh recipes/<NAME>/config.sh
#
# Sources site.sh, then the image's config.sh (which may override it).
#
# Writes builds/<NAME>/<VERSION_TAG>/ containing:
#   <NAME>_<VERSION_TAG>.def   the generated definition
#   inputs/                     copies of site.sh, the config and packages file
#                               used; pixi.toml (the environment spec)
# build.sh then solves inputs/pixi.toml into inputs/pixi.lock and builds.
# The summary and the sbatch command that builds it go to stderr; stdout is
# only the build directory path, so run.sh can capture it.
#
# Needs outbound internet (ghcr.io, anaconda.org, pypi.org) for a few small
# lookups only, so it is fine on a login node. Solving the environment is
# heavier and happens in build.sh on the xfer partition.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || die "usage: $0 recipes/<NAME>/config.sh  (start one with ./new_image.sh <NAME>)"
CONFIG="$1"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"
[[ "$CONFIG" != "$SCRIPT_DIR/config.example.sh" ]] \
    || die "config.example.sh is the template; run ./new_image.sh <NAME> and use its copy"
source "$SCRIPT_DIR/site.sh"
source "$CONFIG"

# Relative PACKAGES_FILE is resolved against the config's directory.
[[ "$PACKAGES_FILE" = /* ]] || PACKAGES_FILE="$(dirname "$CONFIG")/$PACKAGES_FILE"
DEFAULT_PACKAGES="${DEFAULT_PACKAGES-}"

### --- Validate scalar settings ---
[[ -n "${NAME:-}" ]] || die "NAME is not set in $CONFIG"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "NAME '$NAME' must be letters/digits/._- only"
# ${NAME,,} becomes a command in the image (`<name> --help`) and the module
# name; it must not shadow Python's own commands.
[[ ! "${NAME,,}" =~ ^(python|python3|pip|pip3|pixi|conda)$ ]] || die "NAME '$NAME' would shadow a Python/conda command; choose another"
[[ "$VERSION_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "VERSION_TAG '$VERSION_TAG' must be letters/digits/._- only"
[[ "${PYTHON_VERSION:-}" =~ ^3\.[0-9]+$ ]] || die "PYTHON_VERSION must be X.Y, e.g. 3.12 (got '${PYTHON_VERSION:-}')"
[[ "$SNAPSHOT_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "SNAPSHOT_DATE must be YYYY-MM-DD (got '$SNAPSHOT_DATE')"
date -d "$SNAPSHOT_DATE" >/dev/null 2>&1 || die "SNAPSHOT_DATE '$SNAPSHOT_DATE' is not a valid date"
[[ "$SNAPSHOT_DATE" < "$(date +%F)" ]] || die "SNAPSHOT_DATE must be in the past; today's packages are still changing"
[[ " $CHANNELS " != *" defaults "* ]] || die "CHANNELS must not include 'defaults' (see site.sh)"
[[ -f "$PACKAGES_FILE" ]] || die "PACKAGES_FILE not found: $PACKAGES_FILE"
[[ -f "$SCRIPT_DIR/template.def" ]] || die "template.def missing from $SCRIPT_DIR"

OUT_DIR="$BUILDS_DIR/$NAME/$VERSION_TAG"
DEF="$OUT_DIR/${NAME}_${VERSION_TAG}.def"
SIF="$OUT_DIR/${NAME}_${VERSION_TAG}.sif"
[[ -e "$SIF" ]] && die "$SIF already exists. Built images are never overwritten; set a new VERSION_TAG"

### --- Parse and validate package references into pixi.toml entries ---
# Order is kept (DEFAULT_PACKAGES first). Each name may appear once.
declare -a CONDA_TOML=() PYPI_TOML=() REQUESTED=()
declare -A SEEN=()
conda_name_re='[a-z0-9][a-z0-9._-]*'
pypi_name_re='[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?'
spec_re='([<>=!]=?[A-Za-z0-9.*_+!=<>,-]+)?'
add_ref() {
    local ref="$1" src="$2" name spec kind
    if [[ "$ref" =~ ^pypi:(${pypi_name_re})@git\+https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)@(.*)$ ]]; then
        name="${BASH_REMATCH[1]}" kind=pypi
        local owner="${BASH_REMATCH[3]}" repo="${BASH_REMATCH[4]%.git}" rev="${BASH_REMATCH[5]}"
        [[ "$rev" =~ ^[0-9a-f]{40}$ ]] \
            || die "$src: '$ref' must be pinned to a full 40-character commit SHA, not a branch, tag or short SHA"
        PYPI_TOML+=("\"$name\" = { git = \"https://github.com/$owner/$repo\", rev = \"$rev\" }")
    elif [[ "$ref" =~ ^pypi:(${pypi_name_re})(\[[A-Za-z0-9_,.-]+\])?${spec_re}$ ]]; then
        name="${BASH_REMATCH[1]}" kind=pypi
        local extras="${BASH_REMATCH[3]}" spec="${BASH_REMATCH[4]:-*}"
        if [[ -n "$extras" ]]; then
            extras="${extras#[}"; extras="${extras%]}"
            PYPI_TOML+=("\"$name\" = { version = \"$spec\", extras = [\"${extras//,/\", \"}\"] }")
        else
            PYPI_TOML+=("\"$name\" = \"$spec\"")
        fi
    elif [[ "$ref" =~ ^(${conda_name_re})${spec_re}$ ]]; then
        name="${BASH_REMATCH[1]}" kind=conda spec="${BASH_REMATCH[2]}"
        [[ "$name" != python ]] || die "$src: set PYTHON_VERSION in config.sh instead of listing python"
        # conda's "=1.21" means 1.21.*; pixi wants the explicit form.
        [[ "$spec" =~ ^=[^=] ]] && spec="${spec#=}.*"
        CONDA_TOML+=("\"$name\" = \"${spec:-*}\"")
    else
        die "$src: unsupported package reference '$ref' (see packages.txt header for accepted forms)"
    fi
    local key="$kind:${name,,}"
    [[ -z "${SEEN[$key]:-}" ]] || die "$src: '$name' is listed twice"
    SEEN[$key]=1
    REQUESTED+=("$kind $name")
}
for ref in $DEFAULT_PACKAGES; do add_ref "$ref" "DEFAULT_PACKAGES"; done
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"                       # strip comments
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue
    add_ref "$line" "$(basename "$PACKAGES_FILE"):$lineno"
done < "$PACKAGES_FILE"
(( ${#REQUESTED[@]} > 0 )) || die "no packages given"

### --- Check every package exists (catches typos before the xfer job) ---
# Versions are not checked here; the solver in build.sh does that.
for r in "${REQUESTED[@]}"; do
    read -r kind name <<<"$r"
    if [[ "$kind" == conda ]]; then
        found=""
        for ch in $CHANNELS; do
            code=$(curl -s -o /dev/null -w '%{http_code}' "https://api.anaconda.org/package/$ch/$name")
            [[ "$code" == 200 ]] && { found=1; break; }
        done
        [[ -n "$found" ]] || die "conda package '$name' not found in channels: $CHANNELS (on PyPI only? use pypi:$name)"
    else
        code=$(curl -s -o /dev/null -w '%{http_code}' -L "https://pypi.org/pypi/$name/json")
        [[ "$code" == 200 ]] || die "PyPI package '$name' not found (HTTP $code)"
    fi
done

### --- Resolve the base image tag to an immutable digest ---
[[ "$BASE_IMAGE_REPO" == ghcr.io/* ]] || die "BASE_IMAGE_REPO must be on ghcr.io (got $BASE_IMAGE_REPO)"
repo_path="${BASE_IMAGE_REPO#ghcr.io/}"
token=$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo_path}:pull" | jq -r .token) \
    || die "ghcr.io token request failed"
digest=$(curl -fsSI -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${repo_path}/manifests/${BASE_IMAGE_TAG}" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}') \
    || die "tag ${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG} not found"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not resolve digest for ${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG}"

### --- Write pixi.toml ---
mkdir -p "$OUT_DIR/inputs"
channels_toml=$(printf '"%s", ' $CHANNELS); channels_toml="[${channels_toml%, }]"
{
    echo "# GENERATED by containerPy/generate_def.sh from $(basename "$PACKAGES_FILE")."
    echo "[workspace]"
    echo "name = \"${NAME,,}\""
    echo "channels = $channels_toml"
    echo "channel-priority = \"strict\""
    echo "platforms = [\"linux-64\"]"
    echo "exclude-newer = \"$SNAPSHOT_DATE\""
    echo
    echo "[dependencies]"
    echo "python = \"$PYTHON_VERSION.*\""
    (( ${#CONDA_TOML[@]} )) && printf '%s\n' "${CONDA_TOML[@]}"
    if (( ${#PYPI_TOML[@]} )); then
        echo
        echo "[pypi-dependencies]"
        printf '%s\n' "${PYPI_TOML[@]}"
    fi
} > "$OUT_DIR/inputs/pixi.toml"

### --- Render template ---
tpl=$(<"$SCRIPT_DIR/template.def")
subst() { tpl="${tpl//"$1"/"$2"}"; }
subst @BASE_REF@         "${BASE_IMAGE_REPO}@${digest}"
subst @BASE_IMAGE@       "${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG}"
subst @BASE_DIGEST@      "$digest"
subst @NAME@             "$NAME"
subst @CMD@              "${NAME,,}"
subst @VERSION_TAG@      "$VERSION_TAG"
subst @PYTHON_VERSION@   "$PYTHON_VERSION"
subst @SNAPSHOT_DATE@    "$SNAPSHOT_DATE"
subst @CHANNELS@         "$CHANNELS"
subst @MAINTAINER@       "$MAINTAINER"
subst @GENERATED@        "$(date -u +%Y-%m-%dT%H:%M:%SZ) by $USER"
subst @REQUESTED@        "$(printf '%s\n' "${REQUESTED[@]}")"
leftover=$(grep -oE '@[A-Z_]+@' <<<"$tpl" | sort -u | tr '\n' ' ' || true)
[[ -z "$leftover" ]] || die "unfilled template placeholders: $leftover"
printf '%s\n' "$tpl" > "$DEF"

cp "$SCRIPT_DIR/site.sh" "$OUT_DIR/inputs/site.sh"
cp "$CONFIG" "$OUT_DIR/inputs/config.sh"
cp "$PACKAGES_FILE" "$OUT_DIR/inputs/packages.txt"
printf 'BASE_IMAGE=%s\nBASE_DIGEST=%s\n' "${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG}" "$digest" > "$OUT_DIR/inputs/resolved.txt"

cat >&2 <<EOF
Generated: $DEF
  base      ${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG} @ ${digest}
  snapshot  ${SNAPSHOT_DATE} (channels: ${CHANNELS}, strict; PyPI)
  python    ${PYTHON_VERSION}
  packages  $(printf '%s ' "${REQUESTED[@]#conda }" | sed 's/pypi /pypi:/g')
  spec      $OUT_DIR/inputs/pixi.toml (solved into pixi.lock by build.sh)

Review the .def and pixi.toml, then build (run from $SCRIPT_DIR):
  sbatch build.sh $OUT_DIR
EOF
echo "$OUT_DIR"
