# Per-image settings for containerPy. TEMPLATE: don't edit this copy.
# Start a new image with ./new_image.sh <NAME>, which copies this file and
# packages.example.txt to recipes/<NAME>/ (not tracked in git). Site-wide
# settings (paths, channels, maintainer) are in site.sh; any of them can be
# overridden here.

# Image name (letters, digits, '.', '_', '-'). Becomes builds/<NAME>/.
NAME="base_python"

# Python minor version (X.Y). The patch release is whatever conda-forge had
# by SNAPSHOT_DATE; the exact version is pinned in pixi.lock.
PYTHON_VERSION="3.13"

# Snapshot date (YYYY-MM-DD). The solver ignores every conda and PyPI
# package uploaded after this date (pixi's exclude-newer), so the whole
# environment is what you could have installed on that day. Must be in the
# past. new_image.sh fills in yesterday.
# Choosing one:
#   - New image, no constraints: a recent date.
#   - Matching an existing analysis or paper: the date that work was done.
#   - Adding packages to an existing image: reuse that image's date (see its
#     provenance/build_info.txt) so shared packages stay identical.
# Unlike R, version pins (samtools=1.21) are fine here: every conda version
# is a prebuilt binary. The pinned version must exist by SNAPSHOT_DATE.
SNAPSHOT_DATE="2026-10-26"

# One-line description shown by `module help`/`module whatis` once deployed.
# Blank: built from the Python version and package list.
DESCRIPTION="General-purpose Python data science: numpy, pandas, scipy, matplotlib, seaborn, scikit-learn, statsmodels, polars, pyarrow, ipython and more"

# Commands the module puts on PATH once deployed (comma-separated), in
# addition to the image's own <name> command. Blank: python, python3, and
# every command the requested packages provide (see `<name> --help`). Set it
# to just the tools (e.g. "samtools,bcftools") for a tools image that should
# be loadable next to other Python images; without python the module isn't
# in the "python" family.
PROGRAMS=""

# One package reference per line (see the file's header for the syntax).
# Relative paths are resolved against this config's directory.
PACKAGES_FILE="packages.txt"

# Packages always installed in addition to PACKAGES_FILE (space-separated,
# same syntax). Set to "" for none.
DEFAULT_PACKAGES=""

# Build tag. Defaults to today's date; set it explicitly (e.g. "20261008b")
# to build a second image with the same NAME on the same day.
VERSION_TAG="${VERSION_TAG:-$(date +%Y%m%d)}"
