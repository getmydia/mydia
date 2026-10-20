#!/usr/bin/env python3
"""Fail when a first-party crate's lint table drifts from rust-lints.toml.

Usage: scripts/check_rust_lints.py [repo_root]
"""
import pathlib
import sys
import tomllib

SKIP_DIRS = {"target", ".git", "node_modules", "build", ".dart_tool", ".claude", "deps", "_build"}

# Lint roots: (manifest, table) where table is "lints" or "workspace.lints".
WORKSPACE = "server/Cargo.toml"
GLOBS = ["native/*/Cargo.toml", "player/rust/*/Cargo.toml", "plugins/*/Cargo.toml", "plugins-extra/*/Cargo.toml"]
EXCLUDE = {
    "native/cardigann_guest/Cargo.toml",
    # A doc example for the plugin SDK, never linted by check-rust.sh.
    "native/mydia_plugin_sdk/examples/minimal/Cargo.toml",
}


def walk(root):
    stack = [root]
    while stack:
        d = stack.pop()
        for p in d.iterdir():
            if p.is_dir():
                if p.name not in SKIP_DIRS:
                    stack.append(p)
            else:
                yield p


def load(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def check_table(rel, table, canonical, errors):
    for tool, entries in canonical.items():
        have = table.get(tool, {})
        for name, want in entries.items():
            if name not in have:
                errors.append(f"{rel}: missing {tool}.{name}")
            elif have[name] != want:
                errors.append(f"{rel}: {tool}.{name} is {have[name]!r}, canonical is {want!r}")


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    canonical = load(root / "rust-lints.toml")["lints"]
    errors = []

    ws = load(root / WORKSPACE)
    check_table(WORKSPACE, ws.get("workspace", {}).get("lints", {}), canonical, errors)
    for member in sorted((root / "server/crates").glob("*/Cargo.toml")):
        rel = member.relative_to(root).as_posix()
        if load(member).get("lints") != {"workspace": True}:
            errors.append(f"{rel}: needs `[lints]` with only `workspace = true`")

    for pattern in GLOBS:
        for manifest in sorted(root.glob(pattern)):
            rel = manifest.relative_to(root).as_posix()
            if rel in EXCLUDE:
                continue
            check_table(rel, load(manifest).get("lints", {}), canonical, errors)

    extra = sorted(
        p.relative_to(root).as_posix()
        for p in walk(root)
        if p.name in ("clippy.toml", ".clippy.toml") and p.parent != root
    )
    for rel in extra:
        errors.append(f"{rel}: only the repo-root clippy.toml is allowed")

    for e in errors:
        print(e)
    if errors:
        print(f"\n{len(errors)} problem(s). Copy the tables from rust-lints.toml.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
