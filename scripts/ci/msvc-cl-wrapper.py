#!/usr/bin/env python3
#
# Minimal cl.exe adapter for the MSVC CI probe.
#
# QEMU's configure script invokes the selected compiler with GCC-like command
# line syntax.  This shim translates only the common probe/build flags needed
# to reach Meson with the real MSVC compiler.  It is intentionally small and
# should grow only as CI logs prove another translation is needed.

import os
from pathlib import Path
import subprocess
import sys


SAFE_IGNORED_FLAGS = {
    "-fno-common",
    "-fno-pie",
    "-fno-strict-aliasing",
    "-fwrapv",
    "-m64",
    "-no-pie",
    "-pipe",
    "-pthread",
}

DANGEROUS_FLAGS = {
    "-m32",
    "-nostdlib",
    "-r",
}

IGNORED_LINKER_FLAGS = {
    "--as-needed",
    "--build-id",
    "--build-id=none",
    "--no-as-needed",
    "-rpath",
    "-rpath-link",
    "-z",
    "noexecstack",
    "now",
    "relro",
}

COMPILER_DEFAULTS = ["/Zi", "/FS", "/MD", "/Oy-"]
LINKER_DEFAULTS = [
    "/DEBUG:FULL",
    "/PDB:xemu.pdb",
    "/INCREMENTAL:NO",
    "/OPT:REF",
    "/OPT:NOICF",
]
CXX_SOURCE_SUFFIXES = {".cc", ".cpp", ".cxx", ".c++", ".C"}


def add_once(out, value):
    if value.lower() not in {item.lower() for item in out}:
        out.append(value)


def append_std_flag(out, value, compiler_name=""):
    if compiler_name.startswith("clang-cl") and value.startswith("gnu"):
        out.append(f"/clang:-std={value}")
        return

    value = value.replace("gnu", "c", 1)
    if value in {"c11", "c17"}:
        out.append(f"/std:{value}")
    elif value in {"c++14", "c++17", "c++20"}:
        out.append(f"/std:{value}")


def is_cxx_source(path):
    return Path(path).suffix in CXX_SOURCE_SUFFIXES


def append_translated(out, report, source, *values):
    out.extend(values)
    report["translated"].append((source, " ".join(values)))


def append_translated_once(out, report, source, value):
    add_once(out, value)
    report["translated"].append((source, value))


def ignore_flag(report, value):
    report["ignored"].append(value)


def warn_flag(report, value):
    report["unknown"].append(value)


def append_define_include_undef(out, report, arg, value=None):
    prefix = "/" + arg[1]
    translated = prefix + (value if value is not None else arg[2:])
    append_translated(out, report, arg if value is None else f"{arg} {value}", translated)


def append_linker_item(link, report, item):
    if not item:
        return None
    if item in IGNORED_LINKER_FLAGS or item.startswith("--build-id"):
        ignore_flag(report, item)
        return item in {"-rpath", "-rpath-link", "-z"}
    if item.startswith("-l") and len(item) > 2:
        translated = item[2:] + ".lib"
        link.append(translated)
        report["translated"].append((item, translated))
        return False
    if item.startswith("-L") and len(item) > 2:
        translated = "/LIBPATH:" + item[2:]
        link.append(translated)
        report["translated"].append((item, translated))
        return False
    if item.startswith("-"):
        warn_flag(report, item)
    link.append(item)
    return False


def translate_args(args, compiler_name=""):
    compile_only = False
    preprocess_only = False
    assemble_only = False
    output = None
    depfile = None
    dep_target = None
    source_inputs = []
    out = ["/nologo"]
    link = []
    report = {
        "translated": [],
        "ignored": [],
        "unknown": [],
    }

    for flag in COMPILER_DEFAULTS:
        append_translated_once(out, report, "<default>", flag)

    i = 0
    while i < len(args):
        arg = args[i]
        lower_arg = arg.lower()

        if arg == "-c":
            compile_only = True
            append_translated(out, report, arg, "/c")
        elif lower_arg == "/c":
            compile_only = True
            out.append(arg)
        elif arg == "-E":
            preprocess_only = True
            append_translated(out, report, arg, "/E")
        elif arg == "-P":
            ignore_flag(report, arg)
        elif lower_arg in {"/e", "/ep", "/p"}:
            preprocess_only = True
            out.append(arg)
        elif arg == "-S":
            assemble_only = True
            append_translated(out, report, arg, "/S")
        elif lower_arg == "/s":
            assemble_only = True
            out.append(arg)
        elif arg == "-o":
            i += 1
            if i >= len(args):
                raise SystemExit("-o requires an output path")
            output = args[i]
        elif arg.startswith("-o") and len(arg) > 2:
            output = arg[2:]
        elif arg in {"-MD", "-MMD", "-MP"}:
            ignore_flag(report, arg)
        elif arg in {"-MF", "-MQ", "-MT"}:
            i += 1
            if i >= len(args):
                raise SystemExit(f"{arg} requires an argument")
            if arg == "-MF":
                depfile = args[i]
            else:
                dep_target = args[i]
            ignore_flag(report, f"{arg} {args[i]}")
        elif arg.startswith("-MF") and len(arg) > 3:
            depfile = arg[3:]
            ignore_flag(report, arg)
        elif arg.startswith(("-MQ", "-MT")) and len(arg) > 3:
            dep_target = arg[3:]
            ignore_flag(report, arg)
        elif arg == "-include":
            i += 1
            if i >= len(args):
                raise SystemExit("-include requires a header path")
            append_translated(out, report, f"{arg} {args[i]}", "/FI" + args[i])
        elif arg.startswith("-include") and len(arg) > len("-include"):
            append_translated(out, report, arg, "/FI" + arg[len("-include"):])
        elif arg in {"-D", "-I", "-U"}:
            i += 1
            if i >= len(args):
                raise SystemExit(f"{arg} requires an argument")
            append_define_include_undef(out, report, arg, args[i])
        elif arg.startswith(("-D", "-I", "-U")) and len(arg) > 2:
            append_define_include_undef(out, report, arg)
        elif arg in {"-isystem", "-iquote", "-idirafter"}:
            i += 1
            if i >= len(args):
                raise SystemExit(f"{arg} requires an include path")
            append_translated(out, report, f"{arg} {args[i]}", "/I" + args[i])
        elif arg.startswith("-isystem") and len(arg) > len("-isystem"):
            append_translated(out, report, arg, "/I" + arg[len("-isystem"):])
        elif arg in SAFE_IGNORED_FLAGS:
            ignore_flag(report, arg)
        elif arg in DANGEROUS_FLAGS:
            warn_flag(report, arg)
        elif arg in {"-g", "-g3", "-ggdb", "-gdwarf-4"}:
            append_translated_once(out, report, arg, "/Zi")
        elif lower_arg == "/z7":
            append_translated_once(out, report, arg, "/Zi")
        elif arg == "-O0":
            append_translated(out, report, arg, "/Od")
        elif arg in {"-O1", "-O2", "-O3", "-Os"}:
            append_translated(out, report, arg, "/O2")
        elif arg.startswith("-std="):
            before = list(out)
            append_std_flag(out, arg.split("=", 1)[1], compiler_name)
            for value in out[len(before):]:
                report["translated"].append((arg, value))
        elif arg.startswith("-Wl,"):
            skip_next = False
            for item in arg[4:].split(","):
                if skip_next:
                    ignore_flag(report, item)
                    skip_next = False
                    continue
                skip_next = bool(append_linker_item(link, report, item))
        elif arg.startswith("-W"):
            ignore_flag(report, arg)
        elif arg.startswith("-l") and len(arg) > 2:
            append_linker_item(link, report, arg)
        elif arg == "-L":
            i += 1
            if i >= len(args):
                raise SystemExit("-L requires a library path")
            translated = "/LIBPATH:" + args[i]
            link.append(translated)
            report["translated"].append((f"{arg} {args[i]}", translated))
        elif arg.startswith("-L") and len(arg) > 2:
            append_linker_item(link, report, arg)
        elif arg.lower() == "/link":
            link.extend(args[i + 1:])
            break
        elif arg.startswith("-"):
            warn_flag(report, arg)
            out.append(arg)
        else:
            out.append(arg)
            source_inputs.append(arg)

        i += 1

    if output:
        if compile_only:
            append_translated(out, report, "-o " + output, "/Fo" + output)
        else:
            append_translated(out, report, "-o " + output, "/Fe" + output)

    if any(is_cxx_source(source) for source in source_inputs) or any(
        flag.lower().startswith("/std:c++") for flag in out
    ):
        append_translated_once(out, report, "<cxx-default>", "/EHsc")

    if not compile_only and not preprocess_only and not assemble_only:
        out.append("/link")
        out.extend(LINKER_DEFAULTS)
        for flag in LINKER_DEFAULTS:
            report["translated"].append(("<link-default>", flag))
        out.extend(link)

    depinfo = {
        "depfile": depfile,
        "target": dep_target or output,
        "sources": source_inputs,
    }
    return out, report, depinfo


def depfile_escape(value):
    return value.replace("\\", "/").replace(" ", "\\ ")


def write_depfile(depinfo):
    depfile = depinfo.get("depfile")
    target = depinfo.get("target")
    if not depfile or not target:
        return

    sources = depinfo.get("sources") or []
    Path(depfile).parent.mkdir(parents=True, exist_ok=True)
    line = depfile_escape(target) + ":"
    if sources:
        line += " " + " ".join(depfile_escape(source) for source in sources)
    with open(depfile, "w", encoding="utf-8", newline="\n") as dep:
        dep.write(line)
        dep.write("\n")


def emit_report(compiler, translated, report):
    trace = os.environ.get("MSVC_CL_WRAPPER_TRACE")
    has_unknown = bool(report["unknown"])
    if not trace and not has_unknown:
        return

    lines = [
        f"[msvc-cl-wrapper] Command: {compiler} {' '.join(translated)}",
    ]
    if report["translated"]:
        lines.append("[msvc-cl-wrapper] Translated flags:")
        lines.extend(f"  {source} -> {target}" for source, target in report["translated"])
    if report["ignored"]:
        lines.append("[msvc-cl-wrapper] Ignored GCC flags (safe to skip):")
        lines.extend(f"  {value}" for value in report["ignored"])
    if report["unknown"]:
        lines.append("[msvc-cl-wrapper] Unknown/dangerous flags:")
        lines.extend(f"  {value}" for value in report["unknown"])

    message = "\n".join(lines)
    print(message, file=sys.stderr)

    log_path = os.environ.get("MSVC_CL_WRAPPER_LOG")
    if log_path:
        try:
            with open(log_path, "a", encoding="utf-8") as log:
                log.write(message)
                log.write("\n")
        except OSError as exc:
            print(f"[msvc-cl-wrapper] warning: could not write {log_path}: {exc}", file=sys.stderr)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: msvc-cl-wrapper.py <compiler> [args...]")

    compiler = sys.argv[1]
    args = sys.argv[2:]
    compiler_name = Path(compiler).name.lower()

    if "--version" in args or "-v" in args:
        if compiler_name.startswith("clang-cl"):
            subprocess.run([compiler, "--version"], check=False)
        else:
            subprocess.run([compiler, "/Bv"], check=False)
        return 0
    if "-Wl,--version" in args:
        subprocess.run(["link.exe", "/?"], check=False)
        return 0
    if "-dumpmachine" in args:
        print("x86_64-pc-windows-msvc")
        return 0

    translated, report, depinfo = translate_args(args, compiler_name)
    emit_report(compiler, translated, report)

    result = subprocess.run([compiler, *translated])
    if result.returncode == 0:
        write_depfile(depinfo)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
