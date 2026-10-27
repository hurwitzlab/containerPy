# Writes the package tables from pixi_list.json. Run by %post; kept in the
# image so the exact logic is recorded.
import json, os, sys
from importlib import metadata
from pathlib import Path

prov = Path("/opt/provenance")
env = Path(sys.prefix)
pkgs = sorted(json.load(open(prov / "pixi_list.json")), key=lambda p: p["name"].lower())
requested = [l.split() for l in open(prov / "requested_packages.txt") if l.strip()]

def source(p):
    if p["kind"] == "conda":
        return p["source"].rstrip("/").rsplit("/", 1)[-1]    # conda-forge, bioconda
    url = p.get("url") or ""
    if url.startswith("git+"):
        # git+https://github.com/owner/repo(.git)?...#<sha> -> GitHub owner/repo@sha
        repo = url[4:].split("#")[0].split("?")[0].split("@")[0]
        repo = repo.replace("https://github.com/", "").removesuffix(".git")
        return f"GitHub {repo}@{url.rsplit('#', 1)[-1]}"
    return "PyPI"

with open(prov / "package_versions.tsv", "w") as f:
    f.write("Package\tVersion\tSource\tRequested\n")
    for p in pkgs:
        f.write(f"{p['name']}\t{p['version']}\t{source(p)}\t{'yes' if p['is_explicit'] else ''}\n")

with open(prov / "installed_packages.tsv", "w") as f:
    cols = ["name", "version", "build", "kind", "source", "url", "sha256", "md5", "license"]
    f.write("\t".join(cols) + "\n")
    for p in pkgs:
        f.write("\t".join("" if p.get(c) is None else str(p[c]) for c in cols) + "\n")

# Commands provided by the requested packages (python's own are left out).
progs = set()
bindir = env / "bin"
for kind, name in requested:
    if kind == "conda":
        for meta in (env / "conda-meta").glob("*.json"):
            m = json.load(open(meta))
            if m["name"] == name:
                progs.update(f[4:] for f in m.get("files", []) if f.startswith("bin/") and "/" not in f[4:])
    else:
        for f in metadata.distribution(name).files or []:
            path = Path(f.locate()).resolve()
            if path.parent == bindir.resolve():
                progs.add(path.name)
progs = sorted(p for p in progs if os.access(bindir / p, os.X_OK))
(prov / "programs.txt").write_text("".join(p + "\n" for p in progs))
