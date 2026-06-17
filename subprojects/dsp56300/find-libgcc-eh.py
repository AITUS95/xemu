#!/usr/bin/env python3
"""Locate the MinGW GCC unwind archive shipped with Git for Windows/MSYS2."""

import glob
import os
from pathlib import Path


def add_root(roots, value):
    if value:
        roots.append(Path(value))


def iter_roots():
    roots = []

    for name in ("MINGW_PREFIX", "MSYSTEM_PREFIX"):
        add_root(roots, os.environ.get(name))

    add_root(roots, Path(__file__).resolve().parents[2] / ".msvc-mingw-cache" / "mingw64")

    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry:
            continue

        path = Path(entry)
        add_root(roots, path)
        for parent in path.parents:
            add_root(roots, parent)
            if parent.name.lower() == "git":
                add_root(roots, parent / "mingw64")
                break

    for env_name in ("ProgramFiles", "ProgramFiles(x86)"):
        program_files = os.environ.get(env_name)
        if program_files:
            add_root(roots, Path(program_files) / "Git" / "mingw64")

    add_root(roots, Path("C:/msys64/mingw64"))

    seen = set()
    for root in roots:
        try:
            resolved = root.resolve(strict=False)
        except OSError:
            continue

        key = str(resolved).lower()
        if key in seen:
            continue
        seen.add(key)
        yield resolved


def main():
    for name in ("LIBGCC_EH", "LIBGCC_EH_PATH"):
        override = os.environ.get(name)
        if override and Path(override).is_file():
            print(Path(override).resolve(strict=False).as_posix())
            return 0

    matches = []
    for root in iter_roots():
        for pattern in (
            root / "lib" / "gcc" / "x86_64-w64-mingw32" / "*" / "libgcc_eh.a",
            root / "lib" / "gcc" / "*" / "*" / "libgcc_eh.a",
            root / "lib" / "libgcc_eh.a",
        ):
            matches.extend(glob.glob(str(pattern)))

    if matches:
        print(sorted(set(matches), reverse=True)[0].replace("\\", "/"))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
