#!/bin/bash
#SBATCH --job-name=Py_container_build
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --partition=xfer
#SBATCH --qos=xfer
#SBATCH --time=04:00:00
#SBATCH --output=logs/Py_container_build.%j.out
#SBATCH --error=logs/Py_container_build.%j.err
#
# Solve the environment (inputs/pixi.toml -> inputs/pixi.lock), build the
# .sif for a directory produced by generate_def.sh, and export its
# provenance next to it.
#
# Usage (from the repo dir, so logs/ resolves):
#   sbatch build.sh builds/<NAME>/<VERSION_TAG>
#
# An existing inputs/pixi.lock is reused, so retrying a failed build installs
# exactly the same packages. Delete it to solve again.
#
# Runs on the xfer partition: the build needs outbound internet (image pull,
# conda channels, PyPI, GitHub) and is too heavy for a login node.
set -euo pipefail

# sbatch runs a spool copy of this script, so $0 doesn't point at the repo.
SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$SCRIPT_DIR/site.sh"   # only site settings are needed here

[[ $# -eq 1 ]] || { echo "Usage: sbatch build.sh builds/<NAME>/<VERSION_TAG>" >&2; exit 1; }
OUT_DIR="$(cd "$1" && pwd)" || { echo "ERROR: build dir not found: $1" >&2; exit 1; }
DEF=$(find "$OUT_DIR" -maxdepth 1 -name '*.def' | head -n 2)
[[ $(wc -l <<<"$DEF") -eq 1 && -f "$DEF" ]] || { echo "ERROR: expected exactly one .def in $OUT_DIR" >&2; exit 1; }
SIF="${DEF%.def}.sif"
[[ -e "$SIF" ]] && { echo "ERROR: $SIF already exists; built images are never overwritten" >&2; exit 1; }
INPUTS="$OUT_DIR/inputs"
[[ -f "$INPUTS/pixi.toml" && -f "$INPUTS/resolved.txt" ]] \
    || { echo "ERROR: $INPUTS/pixi.toml or resolved.txt missing; regenerate with generate_def.sh" >&2; exit 1; }
BASE_REF=$(awk -F= '$1 == "BASE_IMAGE" {sub(/:[^:\/]*$/, "", $2); repo = $2} $1 == "BASE_DIGEST" {d = $2} END {print repo "@" d}' "$INPUTS/resolved.txt")
[[ "$BASE_REF" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: no base digest in $INPUTS/resolved.txt" >&2; exit 1; }

echo "=== Python container build ==="
echo "job      ${SLURM_JOB_ID:-none} on $(hostname)"
echo "date     $(date)"
echo "def      $DEF"
echo "sif      $SIF"

module load apptainer
apptainer --version
export APPTAINER_BINDPATH=""   # Hazel's default bind path breaks builds
export APPTAINER_CACHEDIR APPTAINER_TMPDIR
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$PIXI_CACHE_ROOT"

# Keep the build off the node's local /tmp entirely. Apptainer bind-mounts the
# host /tmp and /var/tmp into %post and %test; binding a per-job scratch dir
# over both redirects them. (Apptainer warns "destination is already in the
# mount point list", but the scratch bind is mounted on top and wins.)
# TMPDIR covers anything host-side.
BUILD_TMP="$BUILD_TMP_ROOT/${SLURM_JOB_ID:-$$}"
mkdir -p "$BUILD_TMP"
export TMPDIR="$BUILD_TMP"
trap 'rm -rf "$BUILD_TMP"' EXIT

### --- Step 1: solve pixi.toml into pixi.lock (skipped if a lock exists) ---
# Runs pixi from the pinned base image, in a scratch copy of the manifest,
# so only pixi.lock is ever written to inputs/.
if [[ -f "$INPUTS/pixi.lock" ]]; then
    echo "lock     reusing $INPUTS/pixi.lock"
else
    echo "lock     solving $INPUTS/pixi.toml"
    mkdir -p "$BUILD_TMP/lock" "$BUILD_TMP/home"
    cp "$INPUTS/pixi.toml" "$BUILD_TMP/lock/"
    # The base image has no git, which pixi needs for GitHub refs; `pixi
    # exec -s git` puts conda-forge's git on PATH for this command only.
    apptainer exec --cleanenv --home "$BUILD_TMP/home" \
        --bind "$BUILD_TMP:/tmp" --bind "$PIXI_CACHE_ROOT:/pixi-cache" \
        --env PIXI_CACHE_DIR=/pixi-cache,RATTLER_CACHE_DIR=/pixi-cache \
        --pwd /tmp/lock "docker://$BASE_REF" pixi exec -s git -- pixi lock
    cp "$BUILD_TMP/lock/pixi.lock" "$INPUTS/pixi.lock.partial"
    mv "$INPUTS/pixi.lock.partial" "$INPUTS/pixi.lock"
fi

### --- Step 2: build ---
# Build to a temp name so a failed or killed job never leaves a .sif that
# looks finished. %test runs as part of the build. The .def's %files paths
# are relative to the build directory.
PARTIAL="$SIF.partial"
rm -f "$PARTIAL"
trap 'rm -f "$PARTIAL"; rm -rf "$BUILD_TMP"' EXIT
cd "$OUT_DIR"
apptainer build --bind "$BUILD_TMP:/tmp" --bind "$BUILD_TMP:/var/tmp" "$PARTIAL" "$DEF"
mv "$PARTIAL" "$SIF"
trap 'rm -rf "$BUILD_TMP"' EXIT

# Copy provenance out of the image (streamed with tar, so no bind mounts are needed).
PROV="$OUT_DIR/provenance"
mkdir -p "$PROV"
apptainer exec --cleanenv "$SIF" tar -C /opt/provenance -cf - . | tar -C "$PROV" -xf -
apptainer inspect --labels "$SIF" > "$PROV/labels.txt"
apptainer --version > "$PROV/apptainer_version.txt"
(cd "$OUT_DIR" && sha256sum "$(basename "$SIF")" > "$PROV/sif.sha256")
[[ -n "${SLURM_JOB_ID:-}" ]] && echo "$SLURM_JOB_ID" > "$PROV/slurm_job_id.txt"

# Freeze the build: read-only for everyone, including us.
chmod -R a-w "$OUT_DIR"

echo "=== done ==="
echo "image      $SIF ($(du -h "$SIF" | cut -f1))"
echo "lockfile   $PROV/pixi.lock"
echo "packages   $(($(wc -l < "$PROV/package_versions.tsv") - 1)) installed"
