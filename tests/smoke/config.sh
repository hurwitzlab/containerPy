# Smoke-test config: one of each package reference type. Tracked in git.

NAME="smoke_test"
PYTHON_VERSION="3.12"
SNAPSHOT_DATE="2026-10-01"
PACKAGES_FILE="packages.txt"
DEFAULT_PACKAGES=""
VERSION_TAG="${VERSION_TAG:-$(date +%Y%m%d)}"

# Keep test builds out of the real builds/ directory.
BUILDS_DIR="/share/brc/$USER/containerPy_tests/builds"
