# Site settings for containerPy, shared by every image. Tracked in git.
# Sourced by generate_def.sh (before the image's config.sh, which may
# override any of these) and by build.sh.

# Recorded in the image's labels. Defaults to whoever runs the generator.
MAINTAINER="${MAINTAINER:-$USER@ncsu.edu}"

# Base image: Ubuntu + the pixi binary. Resolved to a digest at generate time.
# pixi solves (pixi.lock) and installs the conda/PyPI environment.
BASE_IMAGE_REPO="ghcr.io/prefix-dev/pixi"
PIXI_VERSION="${PIXI_VERSION:-0.83.0}"
BASE_IMAGE_TAG="${PIXI_VERSION}-noble"

# Conda channels in priority order, with strict priority (bioconda's own
# recommended setup). Never add "defaults": Anaconda's channel has licensing
# terms, and mixing it with conda-forge breaks environments.
CHANNELS="conda-forge bioconda"

# Every build gets builds/<NAME>/<VERSION_TAG>/ with the .def, .sif,
# inputs and provenance.
BUILDS_DIR="${BUILDS_DIR:-/rs1/shares/brc/admin/containers/containerPy/builds}"

# Apptainer cache/tmp dirs. These MUST be on scratch, not $HOME (1 GB quota
# fills mid-pull and fails with a misleading exit 255).
APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"
APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"

# pixi's package cache for the lock step (build.sh). Scratch, never $HOME.
PIXI_CACHE_ROOT="/share/brc/$USER/.cache/pixi"

# Per-job directory bound over /tmp and /var/tmp during builds, so nothing is
# written to the build node's local /tmp. Removed when the build job exits.
BUILD_TMP_ROOT="/share/brc/$USER/.apptainer/build-tmp"

# ------------------------------------------------------------
# Deployment as environment modules (deploy.sh)
# ------------------------------------------------------------

CONTAINER_MOD="/rs1/shares/brc/admin/tools/container-mod_v1/container-mod"
# Profile name. developer_tools is tracked as profiles/developer_tools here
# AND in ../custom_containeR; the two copies must stay byte-identical.
DEPLOY_PROFILE="${DEPLOY_PROFILE:-developer_tools}"
# Must match the paths in that profile.
DEPLOY_ROOT="${DEPLOY_ROOT:-/usr/local/usrapps/brc/developer_tools}"
# Shared by all BRC module trees: modules.config (bind paths) and
# module_log.tcl (load logging), both sourced by every modulefile.
BRC_ENV_DIR="/usr/local/usrapps/brc/env"
# Module names already used here are refused, so `module use` of both trees
# never gives two modules with one name.
BRC_MODULES_DIR="/usr/local/usrapps/brc/brc_modules/modules"
# Recorded as the Home Page of each deployed image; also how deploy.sh
# recognises container-mod repos/ entries it owns.
REPO_URL="https://github.com/hurwitzlab/containerPy"
