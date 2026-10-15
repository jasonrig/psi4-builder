# Keep one explicit LTO mode for all Psi4 core targets.
# Psi4 links pybind11::lto even when CMake IPO is set, so retain the target.
function(psi4_benchmark_lto)
    set_property(TARGET pybind11::lto PROPERTY INTERFACE_COMPILE_OPTIONS "")
    set_property(TARGET pybind11::lto PROPERTY INTERFACE_LINK_OPTIONS "")
endfunction()

cmake_language(DEFER CALL psi4_benchmark_lto)
