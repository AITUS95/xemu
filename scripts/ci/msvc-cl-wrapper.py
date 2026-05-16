#!/usr/bin/env python3
#
# Minimal cl.exe adapter for the Windows MSVC CI build.
#
# QEMU's configure script invokes the selected compiler with GCC-like command
# line syntax.  This shim translates only the common probe/build flags needed
# to reach Meson with the real MSVC compiler.  It is intentionally small and
# should grow only as CI logs prove another translation is needed.

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

if os.name == "nt":
    import ctypes


SAFE_IGNORED_FLAGS = {
    "-fdiagnostics-color=auto",
    "-fms-runtime-lib=dll",
    "-fno-common",
    "-fno-pie",
    "-fno-strict-aliasing",
    "-fvisibility=hidden",
    "-fzero-call-used-regs=used-gpr",
    "-mcx16",
    "-fwrapv",
    "-m64",
    "-msse2",
    "-no-pie",
    "-pipe",
    "-pthread",
}

CLANG_CL_SAFE_IGNORED_FLAGS = {
    "-fchar8_t",
    "-fmax-errors=5",
    "/zc:externconstexpr",
    "/zc:preprocessor",
    "/zc:throwingnew",
}

CLANG_CL_SOURCE_WARNING_SUPPRESSIONS = {
    "subprojects/imgui/imgui.cpp": ["-Wno-unused-function"],
    "subprojects/tomlplusplus/src/toml.cpp": ["-Wno-deprecated-literal-operator"],
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

KNOWN_PASSTHROUGH_FLAGS = {
    "-",
    "--print-search-dirs",
    "-?",
    "-dM",
    "-fchar8_t",
    "-ferror-limit=5",
    "-fmax-errors=5",
    "-mpclmul",
    "-msse4.1",
}

BUILD_CONFIG = os.environ.get("MSVC_CL_WRAPPER_BUILD_CONFIG", "profile").lower()
DEBUG_LIKE_BUILD_CONFIGS = {"debug", "renderdoc"}
LINKER_MACHINE = os.environ.get("MSVC_CL_WRAPPER_MACHINE", "X64").upper()
COMPILER_RT_MACHINE = {
    "X64": "x86_64",
    "X86": "i386",
    "ARM64": "aarch64",
}.get(LINKER_MACHINE, LINKER_MACHINE.lower())
CXX_SOURCE_SUFFIXES = {".cc", ".cpp", ".cxx", ".c++", ".C"}


def compiler_defaults():
    if BUILD_CONFIG == "release":
        return ["/MD", "/O2"]
    if BUILD_CONFIG in DEBUG_LIKE_BUILD_CONFIGS:
        return ["/Zi", "/FS", "/MD", "/Oy-", "/Od"]
    return ["/Zi", "/FS", "/MD", "/Oy-", "/O2"]


def linker_defaults():
    defaults = [
        "/INCREMENTAL:NO",
        f"/MACHINE:{LINKER_MACHINE}",
        "/ENTRY:mainCRTStartup",
        "iphlpapi.lib",
    ]
    if BUILD_CONFIG == "release":
        return ["/OPT:REF", "/OPT:ICF", *defaults]
    if BUILD_CONFIG in DEBUG_LIKE_BUILD_CONFIGS:
        return ["/DEBUG:FULL", "/PDB:xemu.pdb", "/OPT:NOREF", "/OPT:NOICF", *defaults]
    return ["/DEBUG:FULL", "/PDB:xemu.pdb", "/OPT:REF", "/OPT:NOICF", *defaults]


def optimization_flag():
    return "/Od" if BUILD_CONFIG in DEBUG_LIKE_BUILD_CONFIGS else "/O2"


def split_response_text(text):
    text = text.strip()
    if not text:
        return []

    if os.name == "nt":
        argc = ctypes.c_int()
        shell32 = ctypes.windll.shell32
        kernel32 = ctypes.windll.kernel32
        shell32.CommandLineToArgvW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
        shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
        kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        kernel32.LocalFree.restype = ctypes.c_void_p

        argv = shell32.CommandLineToArgvW("wrapper " + text, ctypes.byref(argc))
        if not argv:
            raise OSError("CommandLineToArgvW failed")
        try:
            return [argv[i] for i in range(1, argc.value)]
        finally:
            kernel32.LocalFree(argv)

    return shlex.split(text)


def expand_response_args(args, seen=None):
    seen = seen or set()
    expanded = []

    for arg in args:
        if not arg.startswith("@") or len(arg) == 1:
            expanded.append(arg)
            continue

        rsp_path = arg[1:]
        if len(rsp_path) >= 2 and rsp_path[0] == rsp_path[-1] == '"':
            rsp_path = rsp_path[1:-1]
        path = Path(rsp_path)
        if not path.is_absolute():
            path = Path.cwd() / path
        try:
            resolved = path.resolve()
        except OSError:
            expanded.append(arg)
            continue
        if resolved in seen or not resolved.exists():
            expanded.append(arg)
            continue

        seen.add(resolved)
        text = resolved.read_text(encoding="utf-8-sig")
        expanded.extend(expand_response_args(split_response_text(text), seen))

    return expanded


def write_response_file(args):
    rsp = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        suffix=".rsp",
        prefix="msvc-cl-wrapper-",
        delete=False,
    )
    with rsp:
        rsp.write(subprocess.list2cmdline(args))
        rsp.write("\n")
    return rsp.name


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


def append_source_warning_suppressions(out, report, source_inputs, compiler_name):
    if not compiler_name.startswith("clang-cl"):
        return

    normalized_sources = [
        source.replace("\\", "/").lower()
        for source in source_inputs
    ]
    for suffix, warnings in CLANG_CL_SOURCE_WARNING_SUPPRESSIONS.items():
        if not any(source.endswith(suffix) for source in normalized_sources):
            continue
        for warning in warnings:
            append_translated_once(out, report, f"<source:{suffix}>",
                                   "/clang:" + warning)


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
    if item == "-WX":
        link.append("/WX")
        report["translated"].append((item, "/WX"))
        return False
    if item == "--dynamicbase":
        link.append("/DYNAMICBASE")
        report["translated"].append((item, "/DYNAMICBASE"))
        return False
    if item == "--high-entropy-va":
        link.append("/HIGHENTROPYVA")
        report["translated"].append((item, "/HIGHENTROPYVA"))
        return False
    if item == "--nxcompat":
        link.append("/NXCOMPAT")
        report["translated"].append((item, "/NXCOMPAT"))
        return False
    if item == "--no-seh":
        ignore_flag(report, item)
        return False
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
    if item.lower().startswith("/machine:"):
        translated = f"/MACHINE:{LINKER_MACHINE}"
        link.append(translated)
        if item.lower() != translated.lower():
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

    for flag in compiler_defaults():
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
        elif arg == "-TP":
            append_translated(out, report, arg, "/TP")
        elif arg == "--":
            ignore_flag(report, arg)
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
        elif arg == "-x":
            out.append(arg)
            if i + 1 < len(args):
                i += 1
                out.append(args[i])
        elif compiler_name.startswith("clang-cl") and lower_arg in CLANG_CL_SAFE_IGNORED_FLAGS:
            ignore_flag(report, arg)
        elif arg in KNOWN_PASSTHROUGH_FLAGS:
            out.append(arg)
        elif arg == "-fpermissive":
            ignore_flag(report, arg)
        elif arg == "-ftrivial-auto-var-init=zero":
            if compiler_name.startswith("clang-cl"):
                append_translated(out, report, arg, "/clang:-ftrivial-auto-var-init=zero")
            else:
                ignore_flag(report, arg)
        elif arg in SAFE_IGNORED_FLAGS:
            ignore_flag(report, arg)
        elif arg in DANGEROUS_FLAGS:
            warn_flag(report, arg)
        elif arg == "-WX":
            append_translated(out, report, arg, "/WX")
        elif arg == "-MDd":
            append_translated_once(out, report, arg, "/MD")
        elif arg in {"-g", "-g3", "-ggdb", "-gdwarf-4"}:
            append_translated_once(out, report, arg, "/Zi")
        elif lower_arg == "/z7":
            append_translated_once(out, report, arg, "/Zi")
        elif arg == "-O0":
            append_translated(out, report, arg, optimization_flag())
        elif arg in {"-O1", "-O2", "-O3", "-Os"}:
            append_translated(out, report, arg, optimization_flag())
        elif arg.startswith("-std="):
            before = list(out)
            append_std_flag(out, arg.split("=", 1)[1], compiler_name)
            for value in out[len(before):]:
                report["translated"].append((arg, value))
        elif arg.startswith("-std:"):
            before = list(out)
            append_std_flag(out, arg.split(":", 1)[1], compiler_name)
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
            if compiler_name.startswith("clang-cl"):
                append_translated(out, report, arg, "/clang:" + arg)
            else:
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
            skip_next = False
            for item in args[i + 1:]:
                if skip_next:
                    ignore_flag(report, item)
                    skip_next = False
                    continue
                skip_next = bool(append_linker_item(link, report, item))
            break
        elif arg.startswith("/") and len(arg) > 1:
            out.append(arg)
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

    append_source_warning_suppressions(out, report, source_inputs, compiler_name)

    if not compile_only and not preprocess_only and not assemble_only:
        out.append("/link")
        link_defaults = list(linker_defaults())
        if compiler_name.startswith("clang-cl"):
            link_defaults.append(f"clang_rt.builtins-{COMPILER_RT_MACHINE}.lib")
        out.extend(link_defaults)
        for flag in link_defaults:
            report["translated"].append(("<link-default>", flag))
        out.extend(link)

    depinfo = {
        "depfile": depfile,
        "target": dep_target or output,
        "sources": source_inputs,
        "is_link": not compile_only and not preprocess_only and not assemble_only,
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


def emit_report(compiler, translated, report, is_link=False):
    trace = os.environ.get("MSVC_CL_WRAPPER_TRACE", "").lower()
    has_unknown = bool(report["unknown"])
    trace_all = trace in {"1", "true", "all", "verbose"}
    trace_link = trace in {"link", "links"}
    if not trace_all and not (trace_link and is_link) and not has_unknown:
        return

    lines = [
        f"[msvc-cl-wrapper] Command: {compiler} {' '.join(translated)}",
    ]
    include_details = trace_all or (trace_link and is_link)
    if include_details and report["translated"]:
        lines.append("[msvc-cl-wrapper] Translated flags:")
        lines.extend(f"  {source} -> {target}" for source, target in report["translated"])
    if include_details and report["ignored"]:
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
    used_response_file = any(arg.startswith("@") and len(arg) > 1 for arg in args)
    args = expand_response_args(args)

    if "--version" in args or "-v" in args:
        if compiler_name.startswith("clang-cl"):
            subprocess.run([compiler, "--version"], check=False)
        else:
            print("msvc-cl-wrapper: cl.exe version probe skipped; cl /Bv without a source emits a missing-source-filename diagnostic")
        return 0
    if "-Wl,--version" in args:
        subprocess.run(["link.exe", "/?"], check=False)
        return 0
    if "-dumpmachine" in args:
        print("x86_64-pc-windows-msvc")
        return 0

    translated, report, depinfo = translate_args(args, compiler_name)
    command_args = translated
    display_args = translated
    rsp_path = None
    if used_response_file or sum(len(arg) + 1 for arg in translated) > 16000:
        rsp_path = write_response_file(translated)
        command_args = ["@" + rsp_path]
        display_args = command_args

    emit_report(compiler, display_args, report, is_link=depinfo.get("is_link", False))

    result = subprocess.run([compiler, *command_args])
    if rsp_path:
        try:
            os.unlink(rsp_path)
        except OSError:
            pass
    if result.returncode == 0:
        write_depfile(depinfo)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
