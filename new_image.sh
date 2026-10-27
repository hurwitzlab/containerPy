#!/bin/bash
# Start a new image: copy the config and package-list templates to
# recipes/<NAME>/ (not tracked in git), with NAME and SNAPSHOT_DATE filled in.
#
# Usage: ./new_image.sh <NAME>
#
# Then edit recipes/<NAME>/packages.txt (and config.sh if needed) and run
#   ./run.sh recipes/<NAME>/config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <NAME>"
NAME="$1"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "NAME '$NAME' must be letters/digits/._- only"
DIR="$SCRIPT_DIR/recipes/$NAME"
[[ -e "$DIR" ]] && die "$DIR already exists; edit it, or pick another name"

mkdir -p "$DIR"
# Yesterday: the most recent snapshot that has stopped changing.
sed -e "s|^NAME=\"\"|NAME=\"$NAME\"|" \
    -e "s|^SNAPSHOT_DATE=\"\"|SNAPSHOT_DATE=\"$(date -d yesterday +%F)\"|" \
    "$SCRIPT_DIR/config.example.sh" > "$DIR/config.sh"
cp "$SCRIPT_DIR/packages.example.txt" "$DIR/packages.txt"

cat >&2 <<MSG
Created recipes/$NAME/
  config.sh     NAME=$NAME, SNAPSHOT_DATE=$(date -d yesterday +%F), Python 3.12
  packages.txt  empty list

Next:
  1. add packages to   recipes/$NAME/packages.txt
  2. review            recipes/$NAME/config.sh
  3. build             ./run.sh recipes/$NAME/config.sh
MSG
