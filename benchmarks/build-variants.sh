#!/usr/bin/env bash
# Build Psi4 core variants with the dependencies from a completed native build.
# Keep the baseline build and the Psi4 source files unchanged.
set -euo pipefail

if [[ $# -lt 1 || ${1:-} == --help ]]; then
    printf 'Usage: %s BASELINE_BUILD [OUTPUT_DIR] [JOBS] [full|thin ...]\n' "$0"
    printf 'Defaults: OUTPUT_DIR=./build/performance, JOBS=1, variants=full thin\n'
    exit 0
fi
baseline=$(cd "$1" && pwd -P)
output=${2:-$PWD/build/performance}
jobs=${3:-1}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'JOBS must be a positive integer.\n' >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [[ $# -gt 3 ]]; then shift 3; variants=("$@"); else variants=(full thin); fi
for variant in "${variants[@]}"; do
    case "$variant" in full|thin) ;; *) printf 'Unknown variant: %s\n' "$variant" >&2; exit 1 ;; esac
done
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
python="$baseline/runtime/venv/bin/python"
[[ -x "$python" ]] || { printf 'A completed --package build is required.\n' >&2; exit 1; }
export PATH="$baseline/runtime/venv/bin:$PATH"
CPLUS_INCLUDE_PATH="$(brew --prefix eigen@3)/include"
export CPLUS_INCLUDE_PATH
export MACOSX_DEPLOYMENT_TARGET
MACOSX_DEPLOYMENT_TARGET=$(sed -n 's/^CMAKE_OSX_DEPLOYMENT_TARGET:STRING=//p' \
    "$baseline/psi4-core-prefix/src/psi4-core-build/CMakeCache.txt")
unset PYTHONHOME PYTHONPATH PSIDATADIR
export PYTHONDONTWRITEBYTECODE=1

# Replay the CMake arguments recorded by the baseline superbuild.
# CMake records each argument with a semicolon separator. Do not execute shell text.
command_text=$(< "$baseline/psi4-core-prefix/tmp/psi4-core-cfgcmd.txt")
command_text=${command_text#cmd=\'}
command_text=${command_text%\'}
IFS=';' read -r -a recorded <<< "$command_text"
cmake=${recorded[0]}
arguments=()
source_dir=; c_flags=; cxx_flags=; link_flags=
for argument in "${recorded[@]:1}"; do
    [[ "$argument" != -GNinja ]] || break
    arguments+=("$argument")
    case "$argument" in
        -DPSI4_ROOT=*) source_dir=${argument#*=} ;;
        -DCMAKE_C_FLAGS=*) c_flags=${argument#*=} ;;
        -DCMAKE_CXX_FLAGS=*) cxx_flags=${argument#*=} ;;
        -DCMAKE_SHARED_LINKER_FLAGS=*) link_flags=${argument#*=} ;;
    esac
done
[[ -d "$source_dir/psi4" && -n "$cxx_flags" ]] || { printf 'Baseline CMake arguments are incomplete.\n' >&2; exit 1; }
if [[ -d "$baseline/version.git" ]]; then
    export GIT_DIR="$baseline/version.git" GIT_WORK_TREE="$source_dir"
fi

for variant in "${variants[@]}"; do
    variant_dir="$output/$variant"
    runtime="$variant_dir/runtime"
    mkdir -p "$variant_dir"
    printf '\nBuild %s LTO: %s\n' "$variant" "$variant_dir"
    # The deferred CMake hook removes pybind11's extra -flto option.
    # This prevents that option from overriding -flto=thin on the core target.
    "$cmake" -C "$baseline/psi4-core-prefix/tmp/psi4-core-cache-Release.cmake" \
        -S "$source_dir/psi4" -B "$variant_dir/cmake" -G Ninja "${arguments[@]}" \
        -DCMAKE_INSTALL_PREFIX="$runtime" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_PROJECT_INCLUDE="$script_dir/lto.cmake" \
        -DCMAKE_C_FLAGS="$c_flags -flto=$variant" \
        -DCMAKE_CXX_FLAGS="$cxx_flags -flto=$variant" \
        -DCMAKE_SHARED_LINKER_FLAGS="$link_flags -flto=$variant -Wl,-mllvm,-threads=$jobs" \
        -DCMAKE_INSTALL_RPATH="$baseline/stage/lib" \
        > "$variant_dir/configure.log" 2>&1
    /usr/bin/time -l "$cmake" --build "$variant_dir/cmake" --parallel "$jobs" \
        > "$variant_dir/build.log" 2>&1
    "$cmake" --install "$variant_dir/cmake" > "$variant_dir/install.log" 2>&1
    # Use the same Python and installed packages for all variants.
    # A small virtual environment selects this variant's Psi4 module first.
    uv venv --allow-existing --python "$python" "$runtime/venv"
    variant_site=$("$runtime/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
    baseline_site=$("$python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
    printf '%s\n%s\n' "$runtime/lib" "$baseline_site" > "$variant_site/psi4.pth"
    mkdir -p "$runtime/bin"
    mv "$runtime/bin/psi4" "$runtime/bin/psi4-driver"
    cat > "$runtime/bin/psi4" <<'LAUNCHER'
#!/bin/sh
root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)
if [ "${0##*/}" = psi4-python ]; then
    exec "$root/venv/bin/python" -I "$@"
fi
exec "$root/venv/bin/python" -I "$root/bin/psi4-driver" "$@"
LAUNCHER
    chmod +x "$runtime/bin/psi4"
    ln -sfn psi4 "$runtime/bin/psi4-python"
    printf 'Variant: %s\nBaseline: %s\nC flags: %s -flto=%s\nC++ flags: %s -flto=%s\n' \
        "$variant" "$baseline" "$c_flags" "$variant" "$cxx_flags" "$variant" > "$variant_dir/build-settings.txt"
    git -C "$source_dir" rev-parse HEAD >> "$variant_dir/build-settings.txt"
    printf 'Completed %s: %s\n' "$variant" "$runtime"
done
