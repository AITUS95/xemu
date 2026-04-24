#!/usr/bin/env python3
#
# Minimal cl.exe adapter for the MSVC CI probe.
#
# QEMU's configure script invokes the selected compiler with GCC-like command
# line syntax.  This shim translates only the common probe/build flags needed
# to reach Meson with the real MSVC compiler.  It is intentionally small and
# should grow only as CI logs prove another translation is needed.

import os
import subprocess
import sys


IGNORED_FLAGS = {
    "-fno-common",
    "-fno-pie",
    "-fno-strict-aliasing",
    "-fwrapv",
    "-m64",
    "-no-pie",
    "-pthread",
}


def append_std_flag(out, value):
    value = value.replace("gnu", "c", 1)
    if value in {"c11", "c17"}:
        out.append(f"/std:{value}")
    elif value in {"c++14", "c++17", "c++20"}:
        out.append(f"/std:{value}")


def translate_args(args):
    compile_only = False
    output = None
    out = ["/nologo"]
    link = []

    i = 0
    while i < len(args):
        arg = args[i]

        if arg == "-c":
            compile_only = True
            out.append("/c")
        elif arg == "-E":
            out.append("/E")
        elif arg == "-S":
            out.append("/S")
        elif arg == "-o":
            i += 1
            if i >= len(args):
                raise SystemExit("-o requires an output path")
            output = args[i]
        elif arg.startswith("-o") and len(arg) > 2:
            output = arg[2:]
        elif arg == "-include":
            i += 1
            if i >= len(args):
                raise SystemExit("-include requires a header path")
            out.append("/FI" + args[i])
        elif arg.startswith("-include") and len(arg) > len("-include"):
            out.append("/FI" + arg[len("-include"):])
        elif arg in IGNORED_FLAGS:
            pass
        elif arg in {"-g", "-g3", "-ggdb", "-gdwarf-4"}:
            out.append("/Zi")
        elif arg == "-O0":
            out.append("/Od")
        elif arg in {"-O1", "-O2", "-O3", "-Os"}:
            out.append("/O2")
        elif arg.startswith("-std="):
            append_std_flag(out, arg.split("=", 1)[1])
        elif arg.startswith("-Wl,"):
            for item in arg[4:].split(","):
                if item and not item.startswith("--build-id"):
                    link.append(item)
        elif arg.startswith("-W"):
            pass
        elif arg.startswith("-l") and len(arg) > 2:
            link.append(arg[2:] + ".lib")
        elif arg.startswith("-L") and len(arg) > 2:
            link.append("/LIBPATH:" + arg[2:])
        elif arg.startswith("-D") or arg.startswith("-I") or arg.startswith("-U"):
            out.append(arg)
        else:
            out.append(arg)

        i += 1

    if output:
        if compile_only:
            out.append("/Fo" + output)
        else:
            out.append("/Fe" + output)

    if link:
        out.append("/link")
        out.extend(link)

    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: msvc-cl-wrapper.py <compiler> [args...]")

    compiler = sys.argv[1]
    args = sys.argv[2:]

    if "--version" in args or "-v" in args:
        subprocess.run([compiler, "/Bv"], check=False)
        return 0

    translated = translate_args(args)
    if os.environ.get("MSVC_CL_WRAPPER_TRACE"):
        print("msvc-cl-wrapper:", compiler, " ".join(translated), file=sys.stderr)

    return subprocess.run([compiler, *translated]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
