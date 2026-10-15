#!/usr/bin/env bash
# Build Psi4 for macOS with Accelerate. You can also create an unsigned .pkg installer.
# Install the Xcode Command Line Tools and Homebrew before you start.
# Run this script without arguments to open the settings menu. Use --help to show the options.
# Use ./build/PROFILE for build files. The script does not change Psi4 source files.
# Save the .pkg file in the start directory unless --pkg-output specifies a different path.
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Usage: ./build-psi4-macos.sh [options] [source-directory]
Actions (select one; default: --install):
  --install            Build and install Psi4 in the installation directory
  --package            Build an unsigned .pkg installer; do not install Psi4
  --package-only       Create an installer from a completed --package build

Settings:
  --python VERSION|PATH  CPython version or executable path (default: latest)
  --install-dir PATH     Set the installation directory; use only with --install
  --build-dir PATH       Set the build directory; see the default paths below
  --pkg-output FILE      Set the .pkg file path; select --package if no action is set
  --jobs N               Parallel dependency build jobs (default: 2)
  --psi4-jobs N          Parallel Psi4 build jobs (default: 1)
  --max-am N             Set MAX_AM_ERI from 0 through 7 (default: 5)
  --cpu TARGET           auto, portable, or a Clang CPU name (default: auto)
  --macos-min VERSION    Minimum macOS version (default: current major.minor)
  --update-tools         Update Homebrew and build tools (default for builds)
  --no-update-tools      Install missing tools; keep installed tool versions
  --interactive          Open the settings menu before the operation
  --non-interactive      Use command-line settings and defaults without a menu
  -h, --help             Show this help

Default paths:
  Build directory:        <start-dir>/build/<profile>
  Installation directory: ~/.local/psi4-accelerate/<profile> (--install only)
  Installer build files:  <build-dir>/runtime (includes the build virtual environment)
  Installer file:         <start-dir>/Psi4-<bundle>-unsigned.pkg
  Source directory:       psi4/ beside this script (the Git submodule)

<profile> is python-<Python version>-<CPU>-am<MAX_AM_ERI>-macos<minimum version>.
<bundle> is <Psi4 version>-py<Python version>-<CPU>-am<MAX_AM_ERI>.
<start-dir> is the directory where you start this script. ~ is your home directory.
The script shows the resolved paths before it starts the build.
Keep the installation directory outside the source and build directories.

Use latest to select the latest stable CPython version. You can specify any
available version that meets the Python requirement in the Psi4 source.
You can omit minor or patch numbers. For example: 3, 3.15, or 3.15.0.
The auto CPU setting uses Clang to detect this CPU. Use portable for other CPU
generations of the same architecture. Each Psi4 build job can use several GB of memory.
Psi4 selects the Libint version for MAX_AM_ERI.

With --package-only, use the settings from the completed --package build.
Build job counts and --update-tools do not apply to --package-only.
The installer lets you select installation for one user or all users when it runs.

Use the menu to change any setting. With command-line options, add --interactive
to open the menu. Use command-line options if input does not come from a terminal.
For repeated settings, the last value applies. Select only one action.
--prefix is an alias for --install-dir. --no-package is an alias for --install.
You can also set PYTHON_BIN/PYTHON_VERSION, INSTALL_DIR/PREFIX, BUILD_DIR,
PKG_OUTPUT, BUILD_JOBS, PSI4_BUILD_JOBS, and MAX_AM_ERI in the environment.
HELP
}

# Use the same settings for the menu and command-line options.
# An empty path selects the default path shown in --help.
PYTHON_REQUEST=${PYTHON_BIN:-${PYTHON_VERSION:-latest}}
INSTALL_DIR=${INSTALL_DIR:-${PREFIX:-}}; BUILD_DIR=${BUILD_DIR:-}; PKG_OUTPUT=${PKG_OUTPUT:-}
BUILD_JOBS=${BUILD_JOBS:-2}; PSI4_BUILD_JOBS=${PSI4_BUILD_JOBS:-1}
MAX_AM_ERI=${MAX_AM_ERI:-5}; CPU_TARGET=auto
psi4_invocation_dir=$(pwd -P)
MIN_MACOS=$(/usr/bin/sw_vers -productVersion | cut -d. -f1,2)
UPDATE_TOOLS=yes; psi4_cli_action=; psi4_cli_jobs=0; psi4_cli_update=0; psi4_source_set=0
psi4_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/psi4"
psi4_interactive=0
if [[ $# == 0 && -t 0 && -t 2 ]]; then psi4_interactive=1; fi
select_action() {
    [[ -z "$psi4_cli_action" || "$psi4_cli_action" == "$1" ]] \
        || die 'Select only one action: --install, --package, or --package-only.'
    psi4_cli_action=$1
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --python|--install-dir|--prefix|--build-dir|--jobs|--psi4-jobs|--max-am|--cpu|--macos-min|--pkg-output)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Enter a value for $1."
            case "$1" in
                --python) PYTHON_REQUEST=$2 ;; --install-dir|--prefix) INSTALL_DIR=$2 ;;
                --build-dir) BUILD_DIR=$2 ;; --jobs) BUILD_JOBS=$2 ;;
                --psi4-jobs) PSI4_BUILD_JOBS=$2 ;; --max-am) MAX_AM_ERI=$2 ;;
                --cpu) CPU_TARGET=$2 ;; --macos-min) MIN_MACOS=$2 ;;
                --pkg-output) PKG_OUTPUT=$2 ;;
            esac
            case "$1" in --jobs|--psi4-jobs) psi4_cli_jobs=1 ;; esac
            shift 2 ;;
        --install|--no-package) select_action install; shift ;;
        --package) select_action package; shift ;;
        --package-only) select_action package-only; shift ;;
        --update-tools) UPDATE_TOOLS=yes; psi4_cli_update=1; shift ;;
        --no-update-tools) UPDATE_TOOLS=no; psi4_cli_update=0; shift ;;
        --interactive) psi4_interactive=1; shift ;;
        --non-interactive) psi4_interactive=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --)
            shift
            [[ $# -le 1 ]] || die 'Select only one Psi4 source directory.'
            if [[ $# == 1 ]]; then
                [[ "$psi4_source_set" == 0 ]] || die 'Select only one Psi4 source directory.'
                psi4_source=$1
            fi
            break ;;
        -*) die "Option $1 is not valid. Use --help." ;;
        *)
            [[ "$psi4_source_set" == 0 ]] || die 'Select only one Psi4 source directory.'
            psi4_source=$1; psi4_source_set=1; shift ;;
    esac
done
BUILD_ACTION=${psi4_cli_action:-install}
if [[ -n "$PKG_OUTPUT" ]]; then
    [[ "$psi4_cli_action" != install ]] || die 'Use --pkg-output with --package or --package-only.'
    BUILD_ACTION=${psi4_cli_action:-package}
fi
[[ "$BUILD_ACTION" == install || -z "$INSTALL_DIR" ]] \
    || die 'Use --install-dir only with --install. Select the installer destination when you run the installer.'
if [[ "$BUILD_ACTION" == package-only ]]; then
    [[ "$psi4_cli_jobs" == 0 && "$psi4_cli_update" == 0 ]] \
        || die 'Do not use build job counts or --update-tools with --package-only.'
    UPDATE_TOOLS=no
fi

choose_python() {
    local minimum detected version path existing duplicate choice
    local items=(latest 'Latest stable CPython version (uv)')

    # Read the minimum Python version from the source. Use uv to find installed Python versions.
    minimum=$(sed -n 's/^[[:space:]]*find_package(Python[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$psi4_source/CMakeLists.txt" | head -n 1)
    # Expand $arch in jq.
    # shellcheck disable=SC2016
    detected=$("$psi4_uv" python list --only-installed --output-format json "cpython>=${minimum:-3}" |
        "$psi4_jq" -r --arg arch "$psi4_python_arch" '.[] | select(.arch == $arch and .variant == "default") | [.version, .path] | @tsv')
    while IFS=$'\t' read -r version path; do
        [[ -x "$path" ]] || continue
        duplicate=0
        for existing in "${items[@]}"; do
            if [[ "$existing" == /* && "$path" -ef "$existing" ]]; then
                duplicate=1
                break
            fi
        done
        if [[ "$duplicate" == 0 ]]; then
            items+=("$path" "CPython $version  $path")
        fi
    done <<< "$detected"
    items+=(other 'Other... Enter a Python version or executable path')

    choice=$("$psi4_dialog" --stdout --clear --no-tags --title 'Psi4: Select Python' \
        --menu 'Select an installed Python executable, or select latest to use uv.' 0 0 0 "${items[@]}") \
        || die 'You cancelled Python selection.'
    if [[ "$choice" == other ]]; then
        choice=$("$psi4_dialog" --stdout --clear --title 'Psi4: Other Python' \
            --inputbox 'Enter latest, a version such as 3.15, or a Python executable path.' 0 0) \
            || die 'You cancelled Python selection.'
    fi
    PYTHON_REQUEST=${choice:-latest}
}

configure_build() {
    local choice value status prompt
    local items=()
    while true; do
        items=(
            BUILD_ACTION "Action: $BUILD_ACTION"
            source "Source directory: $psi4_source"
            PYTHON_REQUEST "Python: $PYTHON_REQUEST"
            BUILD_DIR "Build directory: ${BUILD_DIR:-./build/PROFILE}"
        )
        if [[ "$BUILD_ACTION" == install ]]; then
            items+=(INSTALL_DIR "Installation directory: ${INSTALL_DIR:-~/.local/psi4-accelerate/PROFILE}")
        else
            items+=(PKG_OUTPUT "Installer file: ${PKG_OUTPUT:-./Psi4-<bundle>-unsigned.pkg}")
        fi
        if [[ "$BUILD_ACTION" != package-only ]]; then
            items+=(
                BUILD_JOBS "Dependency build jobs: $BUILD_JOBS"
                PSI4_BUILD_JOBS "Psi4 build jobs: $PSI4_BUILD_JOBS"
                UPDATE_TOOLS "Update Homebrew and build tools: $UPDATE_TOOLS"
            )
        fi
        items+=(
            MAX_AM_ERI "Maximum angular momentum: $MAX_AM_ERI"
            CPU_TARGET "CPU target: $CPU_TARGET (auto detects this CPU)"
            MIN_MACOS "Minimum macOS version: $MIN_MACOS"
        )
        status=0
        choice=$("$psi4_dialog" --stdout --clear --no-tags --ok-label Edit \
            --extra-button --extra-label Start --title 'Psi4: Build settings' --menu \
            'Select Edit to change a setting. Select Start to continue. Select Cancel to stop. PROFILE identifies Python, CPU, angular momentum, and minimum macOS version. Relative installer paths start in the directory where you start this script.' \
            0 0 0 "${items[@]}") || status=$?
        case "$status" in 0) ;; 3) return ;; *) die 'You cancelled the operation.' ;; esac
        case "$choice" in
            PYTHON_REQUEST) choose_python ;;
            UPDATE_TOOLS)
                if [[ "${!choice}" == yes ]]; then value=no; else value=yes; fi
                UPDATE_TOOLS=$value ;;
            BUILD_ACTION)
                value=$("$psi4_dialog" --stdout --clear --default-item "$BUILD_ACTION" \
                    --menu 'Select the action' 0 0 0 \
                    install 'Build and install Psi4 in the installation directory' \
                    package 'Build an unsigned installer without installation' \
                    package-only 'Create an installer from a completed package build') || continue
                BUILD_ACTION=$value
                if [[ "$BUILD_ACTION" == install ]]; then PKG_OUTPUT=; else INSTALL_DIR=; fi
                if [[ "$BUILD_ACTION" == package-only ]]; then UPDATE_TOOLS=no; fi ;;
            CPU_TARGET)
                value=$("$psi4_dialog" --stdout --clear --menu 'Select the CPU target' 0 0 0 \
                    auto 'Detect this CPU with Clang' \
                    portable 'Use settings for other CPU generations of this architecture' \
                    other 'Enter a Clang CPU name') || continue
                if [[ "$value" == other ]]; then
                    value=$("$psi4_dialog" --stdout --inputbox 'Enter a Clang CPU name, such as apple-m4.' 0 0 "$CPU_TARGET") || continue
                fi
                CPU_TARGET=$value ;;
            source)
                value=$("$psi4_dialog" --stdout --inputbox 'Enter the Psi4 source directory.' 0 0 "$psi4_source") || continue
                psi4_source=$value ;;
            *)
                case "$choice" in
                    INSTALL_DIR) prompt='Enter the installation directory. Leave empty to use ~/.local/psi4-accelerate/PROFILE.' ;;
                    BUILD_DIR) prompt='Enter the build directory. Leave empty to use ./build/PROFILE in the start directory.' ;;
                    BUILD_JOBS) prompt='Enter the number of parallel dependency build jobs.' ;;
                    PSI4_BUILD_JOBS) prompt='Enter the number of parallel Psi4 build jobs. Each job can use several GB of memory.' ;;
                    MAX_AM_ERI) prompt='Enter the maximum angular momentum from 0 through 7.' ;;
                    MIN_MACOS) prompt='Enter the minimum supported macOS version.' ;;
                    PKG_OUTPUT) prompt='Enter the .pkg file path. Leave empty to save Psi4-<bundle>-unsigned.pkg in the start directory.' ;;
                esac
                value=$("$psi4_dialog" --stdout --inputbox "$prompt" 0 0 "${!choice}") || continue
                printf -v "$choice" '%s' "$value" ;;
        esac
    done
}

psi4_system=$(uname -s)
[[ "$psi4_system" == Darwin ]] || die 'Run this script on macOS.'
command -v brew >/dev/null || die 'Install Homebrew: https://brew.sh/'
if [[ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
    die 'Use a native Apple Silicon terminal. Turn off Rosetta.'
fi
psi4_arch=$(uname -m)
case "$psi4_arch" in arm64) psi4_python_arch=aarch64 ;; x86_64) psi4_python_arch=x86_64 ;; *) die 'This script supports only arm64 and x86_64.' ;; esac
if [[ "$psi4_interactive" == 1 ]]; then
    [[ -t 0 && -t 2 ]] || die 'Use --interactive in a terminal.'
    # Install missing menu tools before you select the tool update setting.
    for tool in uv dialog jq; do
        brew list --versions "$tool" >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 brew install --formula "$tool"
    done
    psi4_uv="$(brew --prefix uv)/bin/uv"
    psi4_dialog="$(brew --prefix dialog)/bin/dialog"
    psi4_jq="$(brew --prefix jq)/bin/jq"
    configure_build
fi
psi4_source=$(cd -- "$psi4_source" && pwd -P)
[[ -f "$psi4_source/CMakeLists.txt" && -d "$psi4_source/psi4" ]] \
    || die 'Select a Psi4 source directory. To use the default source, run: git submodule update --init --recursive'
if [[ "$BUILD_ACTION" != package-only ]]; then
    for value in "$BUILD_JOBS" "$PSI4_BUILD_JOBS"; do
        [[ "$value" =~ ^[1-9][0-9]*$ ]] || die 'Set each job count to a whole number greater than 0.'
    done
fi
[[ "$MAX_AM_ERI" =~ ^[0-7]$ ]] || die 'Set MAX_AM_ERI to a whole number from 0 through 7.'
[[ "$MIN_MACOS" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die 'Enter a macOS version such as 27.0.'
[[ "$CPU_TARGET" =~ ^[a-zA-Z0-9_.+-]+$ ]] || die 'Enter auto, portable, or a Clang CPU name.'
[[ -z "$PKG_OUTPUT" || "$PKG_OUTPUT" == *.pkg ]] || die 'Use a .pkg file name for --pkg-output.'

# Update the build tools. Psi4 selects the Libint and Libxc versions.
psi4_tools=(uv)
if [[ "$BUILD_ACTION" != package-only ]]; then psi4_tools+=(boost eigen@3 libomp); fi
if [[ "$UPDATE_TOOLS" == yes && "$BUILD_ACTION" != package-only ]]; then
    brew update
    env -u HOMEBREW_NO_INSTALL_UPGRADE brew install --formula --no-ask "${psi4_tools[@]}"
else
    for tool in "${psi4_tools[@]}"; do
        brew list --versions "$tool" >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 brew install --formula "$tool"
    done
fi
psi4_uv="$(brew --prefix uv)/bin/uv"
unset PYTHONHOME PYTHONPATH
export UV_PYTHON_DOWNLOADS=automatic UV_LINK_MODE=copy PYTHONDONTWRITEBYTECODE=1
case "$PYTHON_REQUEST" in
    latest|[0-9]*)
    psi4_request=$PYTHON_REQUEST
    [[ "$psi4_request" != latest ]] || psi4_request=3
    case "$psi4_request" in
        *.*.*) "$psi4_uv" python install --no-config --no-bin "$psi4_request" ;;
        *) "$psi4_uv" python install --no-config --no-bin --upgrade "$psi4_request" ;;
    esac
    psi4_python=$("$psi4_uv" python find --no-project --system --managed-python "$psi4_request")
    ;;
    *) psi4_python=$("$psi4_uv" python find --no-project --system "$PYTHON_REQUEST") ;;
esac
"$psi4_python" -c 'import platform, sys; assert sys.implementation.name == "cpython", "Use CPython."; assert platform.machine() == sys.argv[1], "Use a Python executable for this CPU architecture."; print(sys.version)' "$psi4_arch"
psi4_python_version=$("$psi4_python" -c 'import platform; print(platform.python_version())')

# Use Clang to detect the CPU target.
# Stop if Clang selects an older Apple CPU family.
psi4_cc=$(xcrun --find clang)
psi4_cxx=$(xcrun --find clang++)
psi4_sdk=$(xcrun --show-sdk-path)
psi4_cpu_brand=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)
if [[ "$psi4_arch" == arm64 ]]; then
    case "$CPU_TARGET" in auto) psi4_cpu_options=(-mcpu=native) ;; portable) psi4_cpu_options=(-mcpu=apple-m1) ;; *) psi4_cpu_options=("-mcpu=$CPU_TARGET") ;; esac
else
    case "$CPU_TARGET" in auto) psi4_cpu_options=(-march=native -mtune=native) ;; portable) psi4_cpu_options=(-march=x86-64 -mtune=generic) ;; *) psi4_cpu_options=("-march=$CPU_TARGET" "-mtune=$CPU_TARGET") ;; esac
fi
psi4_cpu_probe=$("$psi4_cc" "${psi4_cpu_options[@]}" -### -x c -c /dev/null 2>&1)
psi4_cpu=$(printf '%s\n' "$psi4_cpu_probe" | sed -n 's/.*"-target-cpu" "\([^"]*\)".*/\1/p')
[[ -n "$psi4_cpu" && "$psi4_cpu" != generic ]] || die 'Clang cannot identify the CPU target. Update the Command Line Tools or set --cpu to a CPU name.'
if [[ "$CPU_TARGET" == auto && "$psi4_cpu_brand" =~ ^Apple[[:space:]]M([0-9]+) ]]; then
    [[ "$psi4_cpu" == "apple-m${BASH_REMATCH[1]}" ]] || die "The CPU is $psi4_cpu_brand. Clang selected $psi4_cpu. Update the Command Line Tools or select --cpu portable."
fi
# Use the detected CPU name for all dependency builds.
if [[ "$psi4_arch" == arm64 ]]; then psi4_cpu_options=("-mcpu=$psi4_cpu"); fi
psi4_cpu_flags="${psi4_cpu_options[*]}"

# Resolve paths before you check their locations.
psi4_path() { "$psi4_python" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$1"; }
# Use separate directories for each build profile.
# If you set custom paths, use new directories for a different Python version.
psi4_config="python-$psi4_python_version-$psi4_cpu-am$MAX_AM_ERI-macos$MIN_MACOS"
psi4_build=$(psi4_path "${BUILD_DIR:-$psi4_invocation_dir/build/$psi4_config}")
if [[ "$BUILD_ACTION" == install ]]; then
    psi4_prefix=$(psi4_path "${INSTALL_DIR:-$HOME/.local/psi4-accelerate/$psi4_config}")
else
    psi4_prefix="$psi4_build/runtime"
fi
if [[ -n "$PKG_OUTPUT" ]]; then PKG_OUTPUT=$(psi4_path "$PKG_OUTPUT"); fi
if [[ -n "$PKG_OUTPUT" && -d "$PKG_OUTPUT" ]]; then die 'Set --pkg-output to the path of a .pkg file.'; fi
for psi4_output in "$psi4_prefix" "$psi4_build"; do
    [[ "$psi4_output" != / && "$psi4_output" != "$HOME" ]] || die 'Use a separate output directory below your home directory or another writable directory.'
done
case "$psi4_source/" in "$psi4_build/"*) die 'Use a build directory below or outside the Psi4 source directory.' ;; esac
if [[ "$BUILD_ACTION" == install ]]; then
    case "$psi4_prefix/" in "$psi4_source/"*) die 'Keep the installation outside the Psi4 source directory.' ;; esac
    case "$psi4_prefix/" in "$psi4_build/"*) die 'Use separate installation and build directories.' ;; esac
    case "$psi4_build/" in "$psi4_prefix/"*) die 'Use separate installation and build directories.' ;; esac
fi
psi4_venv="$psi4_prefix/venv"
printf '\nAction: %s\nSource directory: %s\nBuild directory: %s\nPython executable: %s\nCPU: %s\nClang CPU target: %s (%s)\nMinimum macOS version: %s\n' \
    "$BUILD_ACTION" "$psi4_source" "$psi4_build" "$psi4_python" "$psi4_cpu_brand" "$psi4_cpu" "$CPU_TARGET" "$MIN_MACOS"
if [[ "$BUILD_ACTION" == install ]]; then
    printf 'Installation directory: %s\nVirtual environment: %s\n\n' "$psi4_prefix" "$psi4_venv"
else
    printf 'Installer build environment: %s\nInstaller file: %s\n\n' "$psi4_prefix" "${PKG_OUTPUT:-$psi4_invocation_dir/Psi4-<bundle>-unsigned.pkg}"
fi
if [[ "$BUILD_ACTION" == package-only ]]; then
    [[ -f "$psi4_prefix/build-configuration.txt" ]] \
        || die 'No completed installer build matches these settings. Run --package first, or select the settings from an existing build.'
else
    mkdir -p "$psi4_build" "$psi4_prefix"
fi
cd "$psi4_build"
if [[ "$BUILD_ACTION" != package-only ]]; then
    psi4_boost=$(brew --prefix boost)
    psi4_eigen=$(brew --prefix eigen@3)
    psi4_omp=$(brew --prefix libomp)
    printf 'int main(void) { return 0; }\n' | "$psi4_cc" "${psi4_cpu_options[@]}" -isysroot "$psi4_sdk" -mmacosx-version-min="$MIN_MACOS" -x c - -o "$psi4_build/cpu-check"
    "$psi4_build/cpu-check"
    "$psi4_uv" venv --allow-existing --python "$psi4_python" "$psi4_venv"
    export PATH="$psi4_venv/bin:$PATH" VIRTUAL_ENV="$psi4_venv"
    # Set the minimum macOS version for the dependencies and the separate Psi4 CMake process.
    export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"

    # Use uv to select the latest compatible packages for this CPython version.
    psi4_optking_url=$(sed -n 's/^[[:space:]]*URL[[:space:]]*\([^[:space:]]*\).*/\1/p' "$psi4_source/external/upstream/optking/CMakeLists.txt")
    "$psi4_uv" pip install --upgrade --python "$psi4_venv/bin/python" "optking @ $psi4_optking_url" \
        numpy scipy qcelemental qcengine networkx pint pydantic msgpack \
        py-cpuinfo psutil packaging pybind11 setuptools cmake ninja

    # Psi4 uses annotated Git tags to identify the source version.
    # If the source repository has no tags, use a separate metadata repository.
    # Read the source files and local changes from the original repository.
    psi4_version=$("$psi4_venv/bin/python" "$psi4_source/psi4/versioner.py" --formatonly --format '{version}')
    if [[ "$psi4_version" == *undef* ]]; then
        psi4_git="$psi4_build/version.git"
        [[ -d "$psi4_git" ]] || git clone --bare --shared "$psi4_source" "$psi4_git"
        git --git-dir "$psi4_git" fetch --no-tags "$psi4_source" HEAD
        git --git-dir "$psi4_git" fetch --tags --no-recurse-submodules https://github.com/psi4/psi4.git
        psi4_head=$(git -C "$psi4_source" rev-parse HEAD)
        psi4_branch=$(git -C "$psi4_source" symbolic-ref -q HEAD || true)
        if [[ -n "$psi4_branch" ]]; then
            git --git-dir "$psi4_git" update-ref "$psi4_branch" "$psi4_head"
            git --git-dir "$psi4_git" symbolic-ref HEAD "$psi4_branch"
        else
            git --git-dir "$psi4_git" update-ref --no-deref HEAD "$psi4_head"
        fi
        export GIT_DIR="$psi4_git" GIT_WORK_TREE="$psi4_source"
        git read-tree HEAD
        git update-index --refresh || [[ $? == 1 ]]  # Permit local source changes.
        psi4_version=$("$psi4_venv/bin/python" "$psi4_source/psi4/versioner.py" --formatonly --format '{version}')
        [[ "$psi4_version" != *undef* ]] || die 'The Git tags do not match the source version metadata.'
    fi
    printf 'Build Psi4 %s\n' "$psi4_version"

    # Use the SDK libblas and liblapack files to link Accelerate.
    # Keep the LP64 ABI. Psi4 Fortran interfaces require 32-bit integers.
    # Set the compiler and linker options to use Homebrew libomp with Apple Clang.
    export BOOST_ROOT="$psi4_boost" MATH_ROOT="$psi4_sdk/usr"
    export CPLUS_INCLUDE_PATH="$psi4_eigen/include"
    export CMAKE_POLICY_VERSION_MINIMUM=3.5 CMAKE_BUILD_PARALLEL_LEVEL="$BUILD_JOBS"
    psi4_omp_flags="-Xpreprocessor -fopenmp -I$psi4_omp/include"
    psi4_flags="-O3 -DNDEBUG $psi4_cpu_flags"
    psi4_pybind11=$("$psi4_venv/bin/python" -m pybind11 --cmakedir)
    cmake -S "$psi4_source" -B "$psi4_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$psi4_prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_OSX_SYSROOT="$psi4_sdk" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_C_COMPILER="$psi4_cc" -DCMAKE_CXX_COMPILER="$psi4_cxx" \
        -DCMAKE_C_FLAGS="$psi4_flags" -DCMAKE_CXX_FLAGS="$psi4_flags" \
        -DCMAKE_PREFIX_PATH="$psi4_boost;$psi4_eigen;$psi4_omp;$psi4_pybind11" \
        -Dpybind11_DIR="$psi4_pybind11" \
        -DEigen3_DIR="$psi4_eigen/share/eigen3/cmake" \
        -DPython_EXECUTABLE="$psi4_venv/bin/python" \
        -DBLAS_TYPE=SYSTEM_NATIVE -DLAPACK_TYPE=SYSTEM_NATIVE \
        -DENABLE_XHOST=OFF -DENABLE_OPENMP=ON -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
        -DOpenMP_C_FLAGS="$psi4_omp_flags" -DOpenMP_CXX_FLAGS="$psi4_omp_flags" \
        -DOpenMP_C_LIB_NAMES=omp -DOpenMP_CXX_LIB_NAMES=omp \
        -DOpenMP_omp_LIBRARY="$psi4_omp/lib/libomp.dylib" \
        -DMAX_AM_ERI="$MAX_AM_ERI" \
        -DCMAKE_INSIST_FIND_PACKAGE_pybind11=ON \
        -DCMAKE_INSIST_FIND_PACKAGE_qcelemental=ON \
        -DCMAKE_INSIST_FIND_PACKAGE_qcengine=ON \
        -DCMAKE_INSIST_FIND_PACKAGE_optking=ON

    # Limit parallel Psi4 build jobs. Each unity build job can use several GB of memory.
    # CMake omits ExternalProject targets for dependencies that it finds in the build directory.
    # Build the dependencies that still have ExternalProject targets.
    psi4_available_targets=$(cmake --build "$psi4_build" --target help)
    psi4_dependency_targets=()
    for target in libint2_external libxc_external gau2grid_external; do
        if [[ "$psi4_available_targets" == *"$target:"* ]]; then psi4_dependency_targets+=("$target"); fi
    done
    if [[ ${#psi4_dependency_targets[@]} -gt 0 ]]; then
        cmake --build "$psi4_build" --target "${psi4_dependency_targets[@]}" --parallel "$BUILD_JOBS"
    fi
    export CMAKE_BUILD_PARALLEL_LEVEL="$PSI4_BUILD_JOBS"
    cmake --build "$psi4_build" --target install --parallel "$PSI4_BUILD_JOBS"
    psi4_site=$("$psi4_venv/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
    printf '%s\n' "$psi4_prefix/lib" > "$psi4_site/psi4.pth"
    # Copy license notices to the runtime files before you remove the build cache.
    for dependency in "$psi4_eigen" "$psi4_build"/external/upstream/*/*-prefix/src/*_external; do
        for notice in "$dependency"/COPYING* "$dependency"/LICENSE*; do
            if [[ -f "$notice" ]]; then
                mkdir -p "$psi4_prefix/share/psi4/licenses/$(basename "$dependency")"
                cp "$notice" "$psi4_prefix/share/psi4/licenses/$(basename "$dependency")/"
            fi
        done
    done
    for notice in "$psi4_site"/pybind11-*.dist-info/licenses/*; do
        if [[ -f "$notice" ]]; then
            mkdir -p "$psi4_prefix/share/psi4/licenses/pybind11"
            cp "$notice" "$psi4_prefix/share/psi4/licenses/pybind11/"
        fi
    done
    printf '%s\n' "$psi4_config" > "$psi4_prefix/build-configuration.txt"
fi

# Use relative paths in the launchers to support spaces and symbolic links.
# Start Python directly to avoid path limits in Python shebangs.
write_launchers() {
    local root=$1 interpreter=$2 driver=$3
    mkdir -p "$root/bin"
    sed 's/argparse.ArgumentParser(description=/argparse.ArgumentParser(prog="psi4", description=/' \
        "$driver" > "$root/bin/psi4-driver"
    cat > "$root/bin/psi4" <<LAUNCHER
#!/bin/sh
name=\${0##*/}
script=\$0
while [ -L "\$script" ]; do
    directory=\$(CDPATH= cd -P -- "\$(dirname -- "\$script")" && pwd)
    target=\$(/usr/bin/readlink "\$script")
    case "\$target" in /*) script=\$target ;; *) script=\$directory/\$target ;; esac
done
root=\$(CDPATH= cd -P -- "\$(dirname -- "\$script")/.." && pwd)
if [ "\$name" = psi4-python ]; then
    exec "\$root/$interpreter" -I "\$@"
fi
exec "\$root/$interpreter" -I "\$root/bin/psi4-driver" "\$@"
LAUNCHER
    chmod +x "$root/bin/psi4"
    ln -sfn psi4 "$root/bin/psi4-python"
}
if [[ "$BUILD_ACTION" != package-only ]]; then
    write_launchers "$psi4_prefix" venv/bin/python "$psi4_prefix/bin/psi4"
    ln -sfn ../../bin/psi4 "$psi4_venv/bin/psi4"
    ln -sfn ../../bin/psi4-python "$psi4_venv/bin/psi4-python"
fi
[[ -f "$psi4_prefix/build-configuration.txt" && "$(< "$psi4_prefix/build-configuration.txt")" == "$psi4_config" ]] \
    || die 'The runtime files do not match these settings. Build them first, or select the settings from the completed build.'

# Do the same chemistry checks before and after you create the installer files.
# Check the mathematics libraries, integral libraries, and relative Python paths.
check_runtime() {
    "$@" <<'PYTHON'
import psi4
psi4.core.be_quiet()
psi4.set_memory('512 MB')
psi4.set_num_threads(2)
psi4.geometry('O\nH 1 0.96\nH 1 0.96 2 104.5')
psi4.set_options({'basis': 'sto-3g', 'scf_type': 'pk'})
pk = psi4.energy('hf')
assert abs(pk + 74.963319052540) < 1e-7, pk
psi4.set_options({'scf_type': 'df'})
df = psi4.energy('hf')
assert abs(pk - df) < 1e-3, (pk, df)
mp2 = psi4.energy('mp2')
assert mp2 < df, (mp2, df)
pbe = psi4.energy('pbe')
assert -76 < pbe < -74, pbe
gradient = psi4.gradient('hf').np
assert gradient.shape == (3, 3) and abs(gradient.sum(axis=0)).max() < 1e-7
print('Chemistry checks passed:', psi4.__version__, pk, df, mp2, pbe)
PYTHON
}
otool -L "$psi4_prefix"/lib/psi4/core*.so | grep -E 'Accelerate\.framework|vecLib\.framework'
check_runtime env -u PSIDATADIR VECLIB_MAXIMUM_THREADS=1 "$psi4_prefix/bin/psi4-python"
if [[ "$BUILD_ACTION" == install ]]; then
    printf 'Installed Psi4: %s/bin/psi4\nPython API: %s/bin/psi4-python\n' "$psi4_prefix" "$psi4_prefix"
fi

if [[ "$BUILD_ACTION" != install ]]; then
    # Copy all runtime files to the installer payload.
    # The installer uses these files without Homebrew, uv, or a compiler.
    psi4_version=$("$psi4_venv/bin/python" -c 'import psi4; print(psi4.__version__)')
    psi4_pkg_version=$(printf '%s\n' "$psi4_version" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')
    psi4_bundle="$psi4_version-py$psi4_python_version-$psi4_cpu-am$MAX_AM_ERI"
    psi4_pkg_output=${PKG_OUTPUT:-$psi4_invocation_dir/Psi4-$psi4_bundle-unsigned.pkg}
    [[ ! -d "$psi4_pkg_output" ]] || die 'Set --pkg-output to the path of a .pkg file.'
    # Keep the payload and metadata in one temporary directory.
    # Remove the directory on exit, including after a failure.
    psi4_pkg_dir=$(mktemp -d "$psi4_build/pkg-stage.XXXXXX")
    psi4_pkg_temp=
    trap 'rm -rf "$psi4_pkg_dir" "$psi4_pkg_temp"' EXIT
    psi4_stage="$psi4_pkg_dir/root"
    psi4_runtime="$psi4_stage/Library/Psi4/$psi4_bundle"
    mkdir -p "$psi4_runtime"
    "$psi4_venv/bin/python" - "$psi4_runtime" "$psi4_prefix" "$psi4_source" "$MIN_MACOS" <<'BUNDLE_PYTHON'
"""Copy the private Python environment and change its Mach-O library paths."""

import filecmp
import os
import platform
import re
import shutil
import subprocess
import sys
import sysconfig
from collections.abc import Callable
from pathlib import Path

runtime, prefix, source = (Path(value).resolve() for value in sys.argv[1:4])
minimum = tuple(int(part) for part in sys.argv[4].split("."))
minimum += (0,) * (3 - len(minimum))
base = Path(sys.base_prefix).resolve()
site = Path(sysconfig.get_path("purelib")).resolve()
python_lib = Path("lib") / f"python{sys.version_info.major}.{sys.version_info.minor}"
bundled_site = runtime / "python" / python_lib / "site-packages"
patterns: tuple[str, ...] = (
    "__pycache__",
    "*.pyc",
    "*.a",
    "include",
    "cmake",
    "pkgconfig",
    "config-*",
    "python*-config",
    "samples",
    "test",
    "tests",
    "idlelib",
    "tkinter",
    "ensurepip",
)
ignore: Callable[[str, list[str]], set[str]] = shutil.ignore_patterns(*patterns)
for name in ("lib", "share"):
    shutil.copytree(prefix / name, runtime / name, symlinks=True, ignore=ignore)
shutil.copytree(base, runtime / "python", symlinks=True, ignore=ignore)
if bundled_site.is_symlink():
    bundled_site.unlink()
elif bundled_site.exists():
    shutil.rmtree(bundled_site)
patterns += (
    "cmake-*.dist-info",
    "ninja",
    "ninja-*.dist-info",
    "pybind11",
    "pybind11-*.dist-info",
    "setuptools",
    "setuptools-*.dist-info",
    "_distutils_hack",
    "distutils-precedence.pth",
    "pkg_resources",
    "psi4.pth",
)
site_ignore: Callable[[str, list[str]], set[str]] = shutil.ignore_patterns(*patterns)
shutil.copytree(site, bundled_site, symlinks=True, ignore=site_ignore)
(bundled_site / "psi4.pth").write_text(
    os.path.relpath(runtime / "lib", bundled_site) + "\n",
    encoding="utf-8",
)
licenses = runtime / "licenses"
licenses.mkdir()
for name in ("COPYING", "COPYING.LESSER", "THIRD-PARTY-LICENSES"):
    shutil.copy2(source / name, licenses / name)
shutil.copy2(prefix / "build-configuration.txt", runtime)

# Map the original file paths to paths in the installer payload.
# Include Homebrew Python frameworks and libraries from Python wheels.
roots = ((site, bundled_site), (base, runtime / "python"), (prefix, runtime))


def _mapped(path: Path) -> Path | None:
    for original, destination in roots:
        if path.is_relative_to(original):
            return destination / path.relative_to(original)
    return None


def _run(*args: str) -> str:
    # Use a fixed tool path and separate arguments for each call.
    result = subprocess.run(args, check=False, text=True, capture_output=True)  # noqa: S603
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout


def _expand(value: str, original: Path) -> Path:
    return Path(
        value.replace("@loader_path", str(original.parent)).replace(
            "@executable_path",
            str(base / "bin"),
        )
    )


def _dependency(value: str, original: Path, rpaths: list[str]) -> Path:
    if value.startswith("@rpath/"):
        candidates = [_expand(rpath, original) / value[7:] for rpath in rpaths]
        candidates += [base / "lib" / value[7:], prefix / "lib" / value[7:]]
    else:
        candidates = [_expand(value, original)]
    for candidate in candidates:
        if str(candidate).startswith(("/usr/lib/", "/System/Library/")):
            return candidate
        if candidate.exists():
            return candidate.resolve()
    raise RuntimeError(
        f"Cannot find {value}. The file {original} requires this library."
    )


def _original(path: Path) -> Path:
    for original, destination in roots:
        if path.is_relative_to(destination):
            return original / path.relative_to(destination)
    raise RuntimeError(f"Cannot find the original path for {path}.")


# Change symbolic links that refer to files outside the installer payload.
# Keep relative links that refer to files inside the payload.
for path in runtime.rglob("*"):
    if path.is_symlink() and not path.resolve().is_relative_to(runtime):
        target = _mapped(path.resolve())
        if target is None:
            raise RuntimeError(
                f"The symbolic link {path} refers to a file outside the payload."
            )
        path.unlink()
        path.symlink_to(os.path.relpath(target, path.parent))

queue = [
    (path, _original(path))
    for path in runtime.rglob("*")
    if path.is_file() and not path.is_symlink()
]
machos: list[Path] = []
external_origins: dict[Path, Path] = {}
for path, original in queue:
    with path.open("rb") as stream:
        magic = stream.read(4)
    if magic not in (
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
    ):
        continue
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        # A python.org executable can contain arm64 and x86_64 code.
        # Keep the code for this installer architecture.
        # Then check its library load commands.
        thin = path.with_name(path.name + ".psi4-thin")
        _run(
            "/usr/bin/lipo",
            str(path),
            "-thin",
            platform.machine(),
            "-output",
            str(thin),
        )
        thin.replace(path)
    headers = _run("/usr/bin/otool", "-l", str(path))
    rpaths = [
        match.group(1) for match in re.finditer(r"\bpath (.*?) \(offset", headers)
    ]
    command = ""
    for line in headers.splitlines():
        key, _, value = line.strip().partition(" ")
        if key == "cmd":
            command = value.strip()
        if (command == "LC_BUILD_VERSION" and key == "minos") or (
            command == "LC_VERSION_MIN_MACOSX" and key == "version"
        ):
            required = tuple(int(part) for part in value.strip().split("."))
            required += (0,) * (3 - len(required))
            if required > minimum:
                raise RuntimeError(
                    f"{original} requires macOS {value.strip()}. Increase --macos-min."
                )
    changes: list[str] = []
    identity = _run("/usr/bin/otool", "-D", str(path)).splitlines()[1:]
    if identity:
        changes += ["-id", "@rpath/" + path.name]
    dependencies = _run("/usr/bin/otool", "-L", str(path)).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(" (compatibility version", maxsplit=1)[0]
        if dependency in identity or dependency.startswith(
            ("/usr/lib/", "/System/Library/")
        ):
            continue
        resolved = _dependency(dependency, original, rpaths)
        if str(resolved).startswith(("/usr/lib/", "/System/Library/")):
            continue
        target = _mapped(resolved)
        if target is None:
            target = runtime / "lib" / resolved.name
            previous = external_origins.get(target, _original(target))
            if target.exists() and not filecmp.cmp(resolved, previous, shallow=False):
                raise RuntimeError(
                    f"The libraries {resolved} and {target} have the same file name "
                    "but different contents."
                )
            if not target.exists():
                shutil.copy2(resolved, target)
                external_origins[target] = resolved
                queue.append((target, resolved))
                # Copy the license files from this dependency.
                for parent in resolved.parents:
                    if parent.parent.parent.name == "Cellar":
                        for pattern in ("LICENSE*", "COPYING*", "NOTICE*"):
                            for notice in parent.glob(pattern):
                                if notice.is_file():
                                    dest = licenses / parent.parent.name
                                    dest.mkdir(exist_ok=True)
                                    shutil.copy2(notice, dest / notice.name)
                        break
        if not target.exists():
            raise RuntimeError(
                f"The installer payload does not contain the library {target}."
            )
        changes += [
            "-change",
            dependency,
            "@loader_path/" + os.path.relpath(target, path.parent),
        ]
    for rpath in rpaths:
        changes += ["-delete_rpath", rpath]
    if changes:
        path.chmod(path.stat().st_mode | 0o200)
        _run("/usr/bin/install_name_tool", *changes, str(path))
    machos.append(path)

# Use ad hoc signatures for arm64 code after you change its library paths.
# Keep the .pkg installer unsigned.
# Developer ID signatures and notarization require a separate release process.
for path in machos:
    _run("/usr/bin/codesign", "--force", "--sign", "-", str(path))
    for line in _run("/usr/bin/otool", "-L", str(path)).splitlines()[1:]:
        dependency = line.strip().split(" (compatibility version", maxsplit=1)[0]
        if dependency.startswith("@rpath/") and dependency.endswith(path.name):
            continue  # This is the library install ID.
        if dependency.startswith("@loader_path/"):
            target = (path.parent / dependency[13:]).resolve()
            if target.is_file() and target.is_relative_to(runtime):
                continue
        elif dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        raise RuntimeError(
            f"The file {path} requires a library outside the installer payload: "
            f"{dependency}."
        )
sys.stdout.write(f"Copied and checked {len(machos)} Mach-O files.\n")
BUNDLE_PYTHON
    write_launchers "$psi4_runtime" python/bin/python3 "$psi4_prefix/bin/psi4-driver"
    ln -s "$psi4_bundle" "$psi4_stage/Library/Psi4/current"
    # Move the payload to a path with spaces. Check the runtime before you create the installer.
    mv "$psi4_stage" "$psi4_pkg_dir/relocated payload"
    psi4_stage="$psi4_pkg_dir/relocated payload"
    psi4_runtime="$psi4_stage/Library/Psi4/$psi4_bundle"
    check_runtime env -i HOME="$HOME" PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" \
        VECLIB_MAXIMUM_THREADS=1 "$psi4_runtime/bin/psi4-python"
    env -i HOME="$HOME" PATH=/usr/bin:/bin "$psi4_runtime/bin/psi4" --version
    find "$psi4_runtime" -type d -name __pycache__ -prune -exec rm -rf '{}' +
    /usr/bin/pkgbuild --root "$psi4_stage" --install-location / \
        --identifier "org.psicode.psi4.$psi4_arch" --version "$psi4_pkg_version" \
        --ownership recommended "$psi4_pkg_dir/runtime.pkg"
    cat > "$psi4_pkg_dir/conclusion.html" <<'HTML'
<html><body><h2>Psi4 installation is complete</h2>
<p>If you installed Psi4 for your user account, add this line to your shell configuration file:</p>
<pre>export PATH="$HOME/Library/Psi4/current/bin:$PATH"</pre>
<p>If you installed Psi4 for all users, add this line to your shell configuration file:</p>
<pre>export PATH="/Library/Psi4/current/bin:$PATH"</pre>
<p>Run <code>psi4 input.dat</code> to use a Psi4 input file.</p>
<p>Run <code>psi4-python script.py</code> to use the Python API.</p>
</body></html>
HTML
    cat > "$psi4_pkg_dir/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Psi4 $psi4_version ($psi4_cpu, Accelerate)</title>
  <options customize="never" require-scripts="false" hostArchitectures="$psi4_arch"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="true"/>
  <volume-check script="true"><allowed-os-versions><os-version min="$MIN_MACOS"/></allowed-os-versions></volume-check>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <choices-outline><line choice="runtime"/></choices-outline>
  <choice id="runtime" visible="false"><pkg-ref id="org.psicode.psi4.$psi4_arch"/></choice>
  <pkg-ref id="org.psicode.psi4.$psi4_arch" version="$psi4_pkg_version">runtime.pkg</pkg-ref>
</installer-gui-script>
XML
    mkdir -p "$(dirname "$psi4_pkg_output")"
    # Create the complete installer before you replace an existing installer file.
    psi4_pkg_temp=$(mktemp -d "$(dirname "$psi4_pkg_output")/.psi4-pkg.XXXXXX")
    /usr/bin/productbuild --distribution "$psi4_pkg_dir/distribution.xml" \
        --package-path "$psi4_pkg_dir" --resources "$psi4_pkg_dir" "$psi4_pkg_temp/installer.pkg"
    mv -f "$psi4_pkg_temp/installer.pkg" "$psi4_pkg_output"
    printf '\nUnsigned installer: %s\n' "$psi4_pkg_output"
fi
