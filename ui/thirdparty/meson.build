libstb_image_c_args = []
if host_os == 'windows'
  libstb_image_c_args += ['-Wno-missing-prototypes']
endif
libstb_image = static_library('stb_image',
                              sources: 'stb_image/stb_image_impl.c',
                              c_args: libstb_image_c_args)
stb_image = declare_dependency(include_directories: 'stb_image',
                               link_with: libstb_image)

fa = declare_dependency(include_directories: 'fa')

if cpu == 'x86_64'
  libfpng_cpp_args = ['-DFPNG_NO_SSE=0', '-msse4.1', '-mpclmul']
else
  libfpng_cpp_args = ['-DFPNG_NO_SSE=1']
endif
if host_os == 'windows'
  libfpng_cpp_args += ['-Wno-unused-function']
endif

libfpng = static_library('fpng', sources: 'fpng/fpng.cpp', cpp_args: libfpng_cpp_args)
fpng = declare_dependency(include_directories: 'fpng', link_with: libfpng)

json_dep = dependency('nlohmann_json', required: true)
json_compile_args = []
if host_os == 'windows'
  json_compile_args += ['-Wno-tautological-overlap-compare']
endif
json = declare_dependency(dependencies: json_dep,
                          compile_args: json_compile_args)
libfatx = static_library('fatx', sources: files('fatx/fatx.c') + genh)
fatx = declare_dependency(include_directories: 'fatx', link_with: libfatx)
