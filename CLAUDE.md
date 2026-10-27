# CLAUDE.md

Guidance for Claude Code when working in this directory.

## Purpose

BRC admins use this to build reproducible Python/conda (conda-forge +
bioconda + PyPI) Apptainer images on the NC State Hazel cluster from a plain
package list. See README.md for usage. Sibling of `../custom_containeR` (R
images): same layout, scripts and rules wherever they aren't R-specific, so
when changing shared behaviour (build.sh, run.sh, new_image.sh, the
`<name> --help` command) check whether the R repo needs the same change.
No LLM step: every image comes from the one `template.def`.

## Pipeline

```
new_image.sh <NAME> -> recipes/<NAME>/{config.sh,packages.txt}  (gitignored copies of *.example*)
site.sh + recipes/<NAME>/config.sh + packages.txt
  -> generate_def.sh   validate, check names on anaconda.org/PyPI, resolve base digest,
                       write inputs/pixi.toml, render template.def
                       -> builds/<NAME>/<VERSION_TAG>/<NAME>_<VERSION_TAG>.def + inputs/
  -> sbatch build.sh builds/<NAME>/<VERSION_TAG>   (xfer partition)
                       pixi lock (in the pinned base image) -> inputs/pixi.lock, unless it exists
                       cd build dir; apptainer build (+%test) -> .sif, export /opt/provenance, chmod a-w
```

## Design rules (don't regress these)

- **The lockfile is the reproducibility contract.** `inputs/pixi.lock` has
  every package's URL + sha256; `%post` runs `pixi install --locked`. The
  `SNAPSHOT_DATE` (`exclude-newer`) only makes the solve repeatable;
  conda-forge repodata patches mean re-solving isn't guaranteed identical,
  so an existing lock is always reused and never silently re-solved.
- Solving happens in `build.sh` on xfer, not in `generate_def.sh`: it
  downloads channel repodata and, for PyPI/git refs, builds metadata, so it
  is too heavy for a login node. `generate_def.sh` only does small lookups.
- Base image `ghcr.io/prefix-dev/pixi:<ver>-noble` pinned by **digest**;
  the lock step runs pixi from the same digest as the build.
- Channels `conda-forge bioconda`, `channel-priority = "strict"`.
  `defaults` is refused (Anaconda licensing; incompatible with conda-forge).
- GitHub refs are full 40-char SHAs only. Any new source type needs a hash
  or immutable ref before it is allowed.
- **Never overwrite a build.** Same as the R repo: `.sif.partial` renamed on
  success, refuse if `.sif` exists, finished dirs `chmod -R a-w`.
- **Builds are committed, images are not** (`.gitignore`: `*.sif`).
- Provenance in two places: `/opt/provenance` in the image and
  `builds/.../provenance/`. `provenance.py` is written into the image so
  the table logic is recorded. Adding keys to `build_info.txt` is safe;
  renaming them breaks `<name> --help` and deploy.sh.
- **Host isolation via `export`, not `unset`** (lesson 2 of the R repo):
  `%environment` exports empty `PYTHONPATH`/`PYTHONHOME`/`PYTHONUSERBASE`/
  `PYTHONSTARTUP`/`PERL5LIB`/`PERLLIB` (CPython ignores empty PYTHON*),
  `PYTHONNOUSERSITE=1`, and `LD_LIBRARY_PATH=/.singularity.d/libs`.
  `%test` sets leaking host values and checks.
- `%environment` sources `/opt/env/activate.sh`, built in `%post` from
  `pixi shell-hook` filtered to PATH/CONDA_* exports and the packages'
  `activate.d` scripts (e.g. openjdk's JAVA_HOME). Don't source the raw
  hook: it defines a `pixi()` function and PS1.
- `pixi install --run-post-link-scripts`: conda runs post-link scripts and
  some bioconda packages need them; pixi skips them by default.
- `git` is not in the base image; pixi runs under `pixi exec -s git --`
  (lock step and `%post`) so GitHub refs work without leaving git in the
  image.
- **Never touch `/tmp` in `%post`** (it is the build node's real `/tmp`);
  `TMPDIR` and pixi's caches go to `/opt/build-tmp`, removed at the end.
- `%post` is unindented on purpose (heredoc terminators at column 0).
- Template placeholders are `@UPPER_CASE@`; the generator fails on leftovers.
  `@CMD@` is `NAME` lowercased (the `<name> --help` command and the module name).
- The `.def`'s `%files` paths are relative; `build.sh` cds to the build dir.

## Deploy (deploy.sh)

Port of custom_containeR's deploy.sh; read that repo's CLAUDE.md for the
container-mod facts it relies on (local image copied to `DEPLOY_ROOT/images`
first, `repos/<app>` written before `container-mod pipe`, bogus DockerHub
help line deleted, `ModulesHelp` switched to stderr, shared Tcl in
`/usr/local/usrapps/brc/env/`, `module_loads.log` parsed by
brc_infra_site). Differences:
- `Programs:` is python, python3, `<name>`, plus `provenance/programs.txt`
  (commands of the *requested* packages), unless the recipe sets
  `PROGRAMS` (must be a subset of those). `family "python"` only when the
  python wrapper is exposed.
- Owns `repos/` entries whose Home Page is `https://github.com/hurwitzlab/containerPy`,
  so it never overwrites custom_containeR's, and vice versa.
- `profiles/developer_tools` must stay byte-identical to custom_containeR's
  copy and container-mod's installed copy (`cmp` check).
- An untracked profile in `~/container-apps/profiles/` is used when there is
  no tracked copy of that name. Test deploys that way, never in developer_tools:
  `sed "s|/usr/local/usrapps/brc/developer_tools|<scratch>|g" profiles/developer_tools > ~/container-apps/profiles/containerpy_test`,
  then `DEPLOY_PROFILE=containerpy_test DEPLOY_ROOT=<scratch> ./deploy.sh --yes <build>`.
  Afterwards remove `<scratch>`, the profile, and container-mod's
  `repos/<name>` (shared). The module-load check logs one line to
  `module_loads.log` with the scratch dir as tree (not counted by brc_infra_site).

## Hazel rules

- Builds run via `sbatch build.sh` on `--partition=xfer --qos=xfer`; submit
  from this directory (`$SLURM_SUBMIT_DIR` locates `site.sh`).
- Apptainer cache/tmp, `PIXI_CACHE_ROOT` and `BUILD_TMP_ROOT` must be on
  `/share/brc/$USER`, never `$HOME` or node-local `/tmp`.
  `APPTAINER_BINDPATH=""` is required for builds.
- `apptainer exec --env HOME=...` is refused; use `--home <dir>`.
- Never ssh to compute/xfer nodes; check jobs with `squeue`/`sacct`.

## Testing changes

```bash
./generate_def.sh tests/smoke/config.sh      # writes to /share/brc/$USER/containerPy_tests
sbatch build.sh /share/brc/$USER/containerPy_tests/builds/smoke_test/<TAG>
```

Then check `provenance/package_versions.tsv` (samtools from bioconda at
1.21.x, toolz `GitHub pytoolz/toolz@<sha>`), `JAVA_HOME` set by openjdk's
activation, and isolation with real host variables:
`PYTHONPATH=/x apptainer exec img.sif python -c 'import sys; print(sys.path)'`.
To rebuild the same tag: `chmod -R u+w <dir> && rm -r <dir>` first.
