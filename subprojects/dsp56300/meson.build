project('dsp56300', 'c', version: '0.1.3')

fs = import('fs')
python = import('python').find_installation()
cc = meson.get_compiler('c')

host_cpu = host_machine.cpu_family()
host_os = host_machine.system()

if host_os == 'darwin'
  os_suffix = 'apple-darwin'
elif host_os == 'windows'
  os_suffix = (host_cpu == 'aarch64') ? 'pc-windows-gnullvm' : 'pc-windows-gnu'
elif host_os == 'linux'
  os_suffix = 'unknown-linux-gnu'
else
  error('Unsupported host OS: ' + host_os)
endif
rust_target = host_cpu + '-' + os_suffix

ver = meson.project_version()
prefix = 'dsp56300-@0@-@1@'.format(ver, rust_target)
archive = '@0@.tar.gz'.format(prefix)
url = 'https://github.com/mborgerson/dsp56300/releases/download/v@0@/@1@'.format(ver, archive)
lib = meson.current_build_dir() / prefix / 'lib' / 'libdsp56300_emu_ffi.a'

if not fs.exists(lib)
  src_archive = meson.current_source_dir() / archive
  if not fs.exists(src_archive)
    message('Downloading dsp56300 @0@ for @1@...'.format(ver, rust_target))
    run_command(find_program('curl'), '-fsSL', url, '-o', src_archive, check: true)
  endif
  run_command(
    python, '-c',
    'import pathlib, sys, tarfile; pathlib.Path(sys.argv[2]).mkdir(parents=True, exist_ok=True); tarfile.open(sys.argv[1], "r:gz").extractall(sys.argv[2])',
    src_archive, meson.current_build_dir(),
    check: true)
endif

link_args = []
if host_os == 'linux'
  link_args = ['-lpthread', '-ldl', '-lm']
elif host_os == 'windows'
  link_args = ['-lbcrypt', '-lntdll', '-luserenv', '-lws2_32']
  if cc.get_linker_id() == 'link'
    gcc_eh = run_command(
      python, meson.current_source_dir() / 'find-libgcc-eh.py',
      check: false).stdout().strip()
    if gcc_eh == ''
      error('libgcc_eh.a was not found; it is required to link the x86_64-pc-windows-gnu dsp56300 archive with MSVC')
    endif
    message('Using MinGW GCC unwind library for dsp56300: ' + gcc_eh)
    link_args += [gcc_eh]
  endif
elif host_os == 'darwin'
  link_args = ['-lpthread', '-lm', '-framework', 'Security']
endif

dsp56300_dep = declare_dependency(
  link_args: [lib] + link_args,
  include_directories: include_directories(prefix / 'include'),
)

meson.override_dependency('dsp56300-emu-ffi', dsp56300_dep)
