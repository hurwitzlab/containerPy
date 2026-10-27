#!/bin/bash
# Full pipeline: generate the .def, then submit the build to the xfer partition.
#
# Usage: ./run.sh [--yes] [--wait] recipes/<NAME>/config.sh
#
#   --yes    submit without asking (required when stdin is not a terminal)
#   --wait   block until the build job ends; exit 0 only if the .sif exists
#
# Runs on a login node: generate_def.sh does small HTTP lookups and build.sh
# goes through sbatch. Both steps still work on their own (see README.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '4,7s/^# \{0,1\}//p' "$0" >&2; exit "${1:-1}"; }

YES=0 WAIT=0 CONFIG=""
while (( $# )); do
    case "$1" in
        -y|--yes)  YES=1 ;;
        -w|--wait) WAIT=1 ;;
        -h|--help) usage 0 ;;
        -*)        echo "ERROR: unknown option $1" >&2; usage ;;
        *)         [[ -z "$CONFIG" ]] || usage; CONFIG="$1" ;;
    esac
    shift
done
[[ -n "$CONFIG" ]] || { echo "ERROR: no config given (start one with ./new_image.sh <NAME>)" >&2; usage; }
# Make the config path absolute before changing directory.
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"
CONFIG="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"

# build.sh finds site.sh via $SLURM_SUBMIT_DIR and writes logs/ relative to
# it, so always submit from the repo dir.
cd "$SCRIPT_DIR"
mkdir -p logs

### --- Step 1: generate ---
OUT_DIR=$(./generate_def.sh "$CONFIG")
DEF=$(find "$OUT_DIR" -maxdepth 1 -name '*.def')
SIF="${DEF%.def}.sif"

### --- Review checkpoint ---
if (( ! YES )); then
    [[ -t 0 ]] || die "not a terminal; review $DEF and re-run with --yes"
    while true; do
        read -r -p "Submit build? [y]es / [v]iew .def / [N]o: " ans
        case "$ans" in
            y|Y|yes) break ;;
            v|V)     "${PAGER:-less}" "$DEF" ;;
            *)       echo "Not submitted. Build later with: sbatch build.sh $OUT_DIR" >&2; exit 0 ;;
        esac
    done
fi

### --- Step 2: build ---
jobid=$(sbatch --parsable build.sh "$OUT_DIR")
jobid="${jobid%%;*}"   # --parsable prints "id;cluster" on multi-cluster setups
echo "Submitted build job $jobid"
echo "  log  $SCRIPT_DIR/logs/Py_container_build.$jobid.out (.err)"
echo "  sif  $SIF"
(( WAIT )) || { echo "Check with: squeue -j $jobid   /   sacct -j $jobid"; exit 0; }

echo "Waiting for job $jobid..."
while [[ -n "$(squeue -h -j "$jobid" 2>/dev/null)" ]]; do sleep 30; done
state=$(sacct -n -X -P -j "$jobid" -o State 2>/dev/null | head -n1 || true)
# The .sif only appears after a successful build (it's renamed from .partial),
# so it, not the sacct state, decides success.
if [[ -f "$SIF" ]]; then
    echo "Build succeeded (${state:-state unknown}): $SIF"
    tail -n 4 "logs/Py_container_build.$jobid.out" 2>/dev/null || true
else
    echo "Build FAILED (${state:-state unknown}). See logs/Py_container_build.$jobid.err" >&2
    exit 1
fi
