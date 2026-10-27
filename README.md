# containerPy

Build reproducible [Apptainer](https://apptainer.org/) images with Python,
conda-forge/bioconda tools and PyPI packages, from a plain list of packages.
You write a package list; the pipeline produces a pinned `.def`, a lockfile
with the exact URL and sha256 of every package, the `.sif`, and a full record
of what was installed.

Sibling of `../custom_containeR` (R images; same layout and workflow) and
`../custom_container_module` (generic tools from GitHub). No LLM step: all
images share one template. Environments are solved and installed with
[pixi](https://pixi.sh).

## Quick start

```bash
cd /rs1/shares/brc/admin/containers/containerPy

# 1. Start a recipe: creates recipes/<NAME>/config.sh + packages.txt
./new_image.sh my_image
# 2. List packages in recipes/my_image/packages.txt; review its config.sh
#    (SNAPSHOT_DATE is set to yesterday, PYTHON_VERSION to 3.12)
# 3. Generate the .def, review it, and submit the build (from a login node)
./run.sh recipes/my_image/config.sh     # asks before submitting; [v] views the .def
```

`run.sh [--yes] [--wait] recipes/<NAME>/config.sh` chains the two steps
below. `--yes` skips the prompt (required when not on a terminal), and
`--wait` blocks until the job ends, exiting non-zero if no `.sif` was
produced. The steps also run on their own:

```bash
./generate_def.sh recipes/<NAME>/config.sh   # validate + write pixi.toml + render .def (login node is fine)
sbatch build.sh builds/<NAME>/<VERSION_TAG>    # solve pixi.lock, build on the xfer partition
```

Builds write nothing to the xfer node's local `/tmp`. Apptainer's cache,
pixi's package cache, and a per-job directory bound over `/tmp` and
`/var/tmp` all live on scratch (`/share/brc/$USER/`; see `site.sh`).

## Where settings live

| File | Tracked | Holds |
|---|---|---|
| `site.sh` | yes | site settings shared by every image: `BUILDS_DIR`, scratch paths, base image + pixi version, `CHANNELS`, `MAINTAINER`, deploy paths |
| `config.example.sh`, `packages.example.txt` | yes | templates; never edited directly |
| `recipes/<NAME>/config.sh`, `packages.txt` | **no** (gitignored) | one image's recipe, made by `new_image.sh` |
| `builds/<NAME>/<TAG>/` | yes, except the `.sif` | one build's `.def`, inputs (including `pixi.lock`) and provenance; commit it after the build |

An image's config is sourced after `site.sh`, so it can override any site
setting (the smoke test overrides `BUILDS_DIR`). To change an image later,
edit its recipe and regenerate with a new `VERSION_TAG` (or on a new day).

## packages.txt syntax

One reference per line, `#` for comments:

| Line | Source |
|---|---|
| `samtools` | conda: conda-forge, then bioconda; newest as of `SNAPSHOT_DATE` |
| `samtools=1.21` | conda, version 1.21 (any 1.21.x build) |
| `numpy>=2.0` | conda, version constraint (`>`, `>=`, `<`, `<=`, `==`, `!=`) |
| `pypi:scanpy` | PyPI, newest as of `SNAPSHOT_DATE` |
| `pypi:scanpy==1.10.4` | PyPI, exact version |
| `pypi:typer[all]` | PyPI with extras |
| `pypi:name@git+https://github.com/owner/repo@<sha>` | GitHub at an exact commit (full 40-character SHA) |

Python itself comes from `PYTHON_VERSION` (X.Y) in `config.sh`; listing
`python` is refused. Prefer conda over `pypi:`: conda packages are prebuilt
with their C libraries and command-line tools. Use `pypi:` only for packages
that aren't on conda-forge or bioconda. `generate_def.sh` checks that every
`pypi:` name exists. A misspelled conda name is reported by the solver in
`build.sh`, about a minute into the job (anaconda.org is too slow to check
every name up front).

To get a GitHub commit SHA:

```bash
curl -s https://api.github.com/repos/<owner>/<repo>/commits/HEAD | jq -r .sha
```

Unlike R images, conda version pins are cheap: every version is a prebuilt
binary. The pinned version must have been uploaded by `SNAPSHOT_DATE`, and
the solver fails if pins conflict.

## How reproducibility works

| Layer | Pinned by |
|---|---|
| OS + pixi | `ghcr.io/prefix-dev/pixi:<PIXI_VERSION>-noble`, resolved to its **sha256 digest** at generate time |
| conda + PyPI | `inputs/pixi.lock`: the exact URL and sha256 of every package, checked at install |
| choice of versions | `exclude-newer = SNAPSHOT_DATE`: the solver ignores anything uploaded after that date (conda and PyPI) |
| GitHub | commit SHA |
| apt | nothing installed; the base image's packages are logged in `dpkg_packages.tsv` |

The **lockfile** is the contract, not the date. conda-forge edits the
dependency metadata of old packages ("repodata patches"), so solving the
same `pixi.toml` twice could in principle give different results. The
lock is solved once by `build.sh`, saved as `inputs/pixi.lock`, and reused
by every later build from that directory. Rebuilding a committed build dir
installs byte-identical packages. The date only makes the solve repeatable
and lets you say "the environment as of this day".

conda channels: `conda-forge` then `bioconda`, with strict priority
(bioconda's own recommended setup). Anaconda's `defaults` channel is
refused: it has licensing terms and doesn't mix with conda-forge.

Post-link scripts are run (`--run-post-link-scripts`), as conda does. A few
bioconda packages need them, e.g. Bioconductor data packages download their
data there.

Not hash-pinned: what post-link scripts download, and the build tools
(e.g. setuptools) used to build a wheel from a GitHub ref or a PyPI
source-only package. The installed package versions are still exactly those
in the lock. A clean rebuild from the saved lock was verified to install
identical packages (same names, versions and sha256).

## Output

```
builds/<NAME>/<VERSION_TAG>/
├── <NAME>_<VERSION_TAG>.def      generated definition
├── <NAME>_<VERSION_TAG>.sif      the image
├── inputs/                       site.sh, config.sh, packages.txt; pixi.toml, pixi.lock; resolved.txt
└── provenance/                   (also inside the image at /opt/provenance)
    ├── pixi.toml, pixi.lock      spec and lockfile
    ├── default_linux-64_conda_spec.txt   explicit conda spec (conda part only)
    ├── pixi_list.json            every package: version, build, channel, URL, sha256
    ├── package_versions.tsv      package, version, source, requested (what `<name> --help` shows)
    ├── installed_packages.tsv    flat table: name, version, build, kind, source, url, sha256, md5, license
    ├── programs.txt              commands provided by the requested packages
    ├── dpkg_packages.tsv         OS packages of the base image
    ├── build_info.txt            base digest, Python, pixi version, channels, dates
    ├── requested_packages.txt
    ├── provenance.py             the script that wrote the tables
    ├── labels.txt, apptainer_version.txt, slurm_job_id.txt
    └── sif.sha256
```

After a successful build the directory is made read-only (`chmod -R a-w`).
To delete a build on purpose: `chmod -R u+w builds/<NAME>/<TAG> && rm -r ...`.
Commit everything but the `.sif` once the build succeeds:

```bash
git add builds/<NAME>/<TAG> && git commit -m "Build <NAME> <TAG>"
```

To retry a failed build with the same packages, re-submit `build.sh` (the
lock is reused). To solve again (e.g. after editing `inputs/pixi.toml` by
hand), delete `inputs/pixi.lock` first.

## Using an image

```bash
module load apptainer
apptainer exec <image>.sif python analysis.py
apptainer exec <image>.sif samtools --version       # tools are on PATH
apptainer run  <image>.sif                          # interactive Python
apptainer exec <image>.sif <name> --help            # what's inside
```

| Command | Prints |
|---------|--------|
| `<name> --help` | Python version, snapshot date, channels, base digest, build date, maintainer, the requested packages with version and source, and the commands they provide |
| `<name> --all` | every package in the image, same columns |
| `<name> --system` | apt packages |
| `<name> --lockfile` | `pixi.lock` |
| `<name> --version` | one line: name, tag, Python, snapshot |

The image ignores host Python and Perl settings: `PYTHONPATH`,
`PYTHONHOME`, `~/.local` site-packages, `PERL5LIB` and host
`LD_LIBRARY_PATH` (e.g. from loaded modules). `%test` fails the build if any
of them leak in, if a requested package is missing, or if a listed command
isn't on `PATH`.

## Deploying as a module

```bash
./deploy.sh builds/<NAME>/<TAG>       # login node; asks before deploying
```

This publishes the image as module `<name>/<TAG>` (name lowercased) under
`/usr/local/usrapps/brc/developer_tools`, next to the R images from
custom_containeR, using container-mod with the `developer_tools` profile.
Users then run:

```bash
module use /usr/local/usrapps/brc/developer_tools/modules
module load my_image/20261027
my_image --help        # packages, versions and commands
python my_script.py    # wrappers run inside the image
samtools view ...      # so do the requested packages' commands
```

The module puts a wrapper on `PATH` for each of these commands:

| Default (`PROGRAMS=""`) | With `PROGRAMS="samtools,bcftools"` in the recipe |
|---|---|
| `python`, `python3`, `<name>`, and every command of the requested packages (`provenance/programs.txt`, shown by `<name> --help`) | only those (each must be in `programs.txt`), plus `<name>` |
| `family "python"`: loading a second Python image is refused | no family: can be loaded next to other images |

Use `PROGRAMS` for tool images, so `python` and the dependencies' commands
don't shadow other modules.

`deploy.sh`:

1. verifies the build (the `.sif` matches `provenance/sif.sha256`)
2. refuses to overwrite a deployed version, to reuse a module name that
   exists in `brc_modules`, or to overwrite another tool's container-mod
   `repos/` entry (custom_containeR's entries have a different Home Page)
3. writes `repos/<name>` (Description, Home Page, Programs). The description
   is `DESCRIPTION` from the recipe's `config.sh`, or one built from the
   Python version and package list
4. copies the `.sif` to `developer_tools/images/` and runs `container-mod pipe`
5. appends `family "python"` (if python is exposed), the shared logging hook
   and the load-time `<name> --help` reminder; switches container-mod's
   `ModulesHelp` from stdout to stderr so `module help` works
6. loads the module, checks every wrapper is on `PATH`, every requested
   package is present and `python` runs, then logs to `logs/deploy.log`.
   If any step fails, it removes what it created.

`profiles/developer_tools` is a byte-identical copy of custom_containeR's;
`deploy.sh` refuses to run if it differs from container-mod's installed copy.

## Recreating the environment outside the container

```bash
cd builds/<NAME>/<TAG>/inputs && pixi install --frozen           # conda + PyPI, exactly
micromamba create -p ./env --file ../provenance/default_linux-64_conda_spec.txt   # conda part only
```

## Validation done by generate_def.sh

- `NAME`/`VERSION_TAG` charset; `NAME` must not shadow `python`, `pip`, `pixi`, `conda`
- `PYTHON_VERSION` is X.Y; `SNAPSHOT_DATE` is a valid past date
- `CHANNELS` doesn't include `defaults`
- every package line is a supported form, listed once; GitHub refs are full SHAs
- every `pypi:` package exists on PyPI (conda names are checked by the solver in `build.sh`, which fails within a minute)
- the base image tag exists (digest lookup)
- refuses if the target `.sif` already exists

## Files

| File | Purpose |
|---|---|
| `new_image.sh` | start an image: copy the templates to `recipes/<NAME>/` |
| `config.example.sh`, `packages.example.txt` | recipe templates |
| `site.sh` | site settings, sourced before the image config and by `build.sh` |
| `template.def` | the single template; `@PLACEHOLDER@`s filled by the generator |
| `generate_def.sh` | validate inputs, write `pixi.toml`, resolve digest, render `.def` |
| `build.sh` | sbatch script (xfer): solve `pixi.lock`, build, export provenance, freeze |
| `deploy.sh` | publish a build as a `developer_tools` module via container-mod |
| `profiles/developer_tools` | container-mod profile (identical copy of custom_containeR's) |
| `run.sh` | pipeline wrapper: `generate_def.sh`, review prompt, `sbatch build.sh`, optional wait |
| `tests/smoke/` | config + packages exercising each reference type |

## Not (yet) included

- GPU (CUDA) environments
- Building from an existing `environment.yml` or `pixi.lock`
