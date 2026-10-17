# syntax=docker/dockerfile:1

# Run these commands from the psi4-builder repository root.
# Initialize the source first: git submodule update --init --recursive
# Local ARM64 image:
#   docker buildx build -f Dockerfile --platform linux/arm64 --load -t psi4:arm64 \
#     --build-arg PSI4_REVISION="$(git -C psi4 rev-parse HEAD)" ./psi4
# Multi-arch release (use native builder nodes where possible; emulation is slow):
#   docker buildx create --name psi4 --driver docker-container --bootstrap
#   docker buildx build --builder psi4 -f Dockerfile --platform linux/arm64,linux/amd64 \
#     --build-arg PSI4_REVISION="$(git -C psi4 rev-parse HEAD)" --push -t REGISTRY/psi4:TAG ./psi4
# Without a registry, use --output type=oci,dest=/tmp/psi4.tar for both platforms.
# Run Psithon (host UID/GID permits writing output on the mounted directory):
#   docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" psi4:arm64 -i input.dat -n 4
# Run Python:  docker run --rm --entrypoint /opt/venv/bin/python psi4:arm64 -c 'import psi4'
# Rebuild regularly and update these multi-platform index digests together.
ARG PYTHON_IMAGE=python:3.15.0-slim-trixie@sha256:f48fda6d59b2b3437781d1c3ccf4aa0e26ae871de3cdd758b49ab45ee7291619
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.13.1@sha256:4a1f3666816dafadd20ceb71eac9a7d56d7ef30279f7d64048519ab901ada336
ARG GCC_ARM64_IMAGE=gcc:16.2.0@sha256:17043c23ec2ad97fc3beca18da77275d26be5db5cd70ea0a5d73200e21a8e999
ARG GCC_AMD64_IMAGE=gcc:15.3.0@sha256:1fdcd041afad61e21d4ca0f8046e36f8da61baaa815f5ba290e39a15c487926a
ARG RUNTIME_IMAGE=gcr.io/distroless/base-debian13:nonroot@sha256:a0d70d6a97cd697d9362bc2aae4a6560dd65817e365d0043b07325a97975dc91

FROM ${UV_IMAGE} AS uv
FROM ${GCC_ARM64_IMAGE} AS toolchain-arm64
FROM ${GCC_AMD64_IMAGE} AS toolchain-amd64
# GCC 16's x86 x87 code fails OpenBLAS complex-rotation tests under Rosetta;
# GCC 15.3 passes the reproducer. Keep GCC 16's Apple tuning on ARM64.
FROM toolchain-${TARGETARCH} AS toolchain

# Prepare the source with the build host. Git data is independent of the target CPU.
# The submodule .git file refers outside the context. Create build-local Git data
# so Psi4 can compute its version from the selected commit and upstream tags.
FROM --platform=$BUILDPLATFORM ${PYTHON_IMAGE} AS source
ARG PSI4_REVISION
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN test "${#PSI4_REVISION}" -eq 40 || { echo 'Set PSI4_REVISION to the full Psi4 commit hash.' >&2; exit 1; }; \
    git init -q && \
    git fetch --quiet --no-tags https://github.com/jasonrig/psi4.git "$PSI4_REVISION" && \
    git fetch --quiet --tags https://github.com/psi4/psi4.git && \
    git reset --quiet --mixed "$PSI4_REVISION"

# Use target-platform Python and compilers, never the build host's ABI.
FROM ${PYTHON_IMAGE} AS build
ARG TARGETARCH
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/usr/local/bin:/usr/bin:/bin \
    UV_PYTHON_DOWNLOADS=never \
    UV_LINK_MODE=copy \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_POLICY_VERSION_MINIMUM=3.5
COPY --from=uv /uv /usr/local/bin/uv
# GCC 16 adds Apple M-series tuning absent from Debian 13's default GCC 14.
# Copy only its relocatable toolchain, keeping the Python/Debian base consistent.
COPY --from=toolchain /usr/local/ /usr/local/
ENV LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib

# OS tools remain in this stage. Scientific libraries and build tools below are
# installed independently of Debian's older scientific-package releases.
RUN apt-get update && apt-get install -y --no-install-recommends \
        binutils \
        ca-certificates \
        git \
        libc6-dev \
        make \
        pkg-config \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Create the venv with official CPython. OptKing's source URL follows this
# checkout's CMake configuration; OptKing isn't published on PyPI.
COPY external/upstream/optking/CMakeLists.txt /tmp/optking-cmake.txt
RUN --mount=type=cache,id=psi4-uv-${TARGETARCH},target=/root/.cache/uv <<'DEPS'
set -eu
uv venv --python /usr/local/bin/python /opt/venv
optking_url=$(sed -n 's/^[[:space:]]*URL[[:space:]]*\([^[:space:]]*\).*/\1/p' /tmp/optking-cmake.txt)
uv pip install --python /opt/venv/bin/python "optking @ $optking_url" \
    numpy scipy qcelemental qcengine networkx pint pydantic msgpack \
    py-cpuinfo psutil packaging pybind11 setuptools pytest cmake ninja
DEPS

# Current Boost headers. They are build-only and never enter the runtime image.
ADD --checksum=sha256:ea7b982002cc9dfbe59b0b217b206f470dc75f3de0bb2973d844118934d82411 \
    https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-b2-nodocs.tar.xz /tmp/boost.tar.xz
RUN mkdir -p /opt/boost && tar -xJf /tmp/boost.tar.xz -C /opt/boost --strip-components=1 && rm /tmp/boost.tar.xz

# Use the latest compatible Eigen 3; Eigen 5 changes the major package version.
ADD --checksum=sha256:b93c667d1b69265cdb4d9f30ec21f8facbbe8b307cf34c0b9942834c6d4fdbe2 \
    https://gitlab.com/libeigen/eigen/-/archive/3.4.1/eigen-3.4.1.tar.gz /tmp/eigen.tar.gz
RUN mkdir /tmp/eigen && tar -xzf /tmp/eigen.tar.gz -C /tmp/eigen --strip-components=1 && \
    cmake -S /tmp/eigen -B /tmp/eigen-build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/eigen -DBUILD_TESTING=OFF \
        -DEIGEN_BUILD_BLAS=OFF -DEIGEN_BUILD_LAPACK=OFF -DEIGEN_BUILD_DOC=OFF && \
    cmake --install /tmp/eigen-build && rm -rf /tmp/eigen /tmp/eigen-build /tmp/eigen.tar.gz

# Build current OpenBLAS separately so retries of Psi4 reuse the completed BLAS.
# LP64 is required by Psi4. Dynamic dispatch chooses vector kernels at runtime,
# and USE_OPENMP shares GCC's OpenMP runtime with Psi4. Linux containers cannot
# link macOS Accelerate, even on Apple Silicon hosts.
# Limit parallel compilation to fit the available build memory.
ARG BUILD_JOBS=3
ADD --checksum=sha256:cd7e129868320cc2d033afa920e31202dfe0b8066a5b66661900ccc0f197dfed \
    https://github.com/OpenMathLib/OpenBLAS/releases/download/v0.3.34/OpenBLAS-0.3.34.tar.gz /tmp/openblas.tar.gz
RUN <<'BLAS'
set -eu
mkdir /tmp/openblas
tar -xzf /tmp/openblas.tar.gz -C /tmp/openblas --strip-components=1
case "$TARGETARCH" in arm64) baseline=ARMV8 ;; amd64) baseline=CORE2 ;; *) exit 1 ;; esac
make -C /tmp/openblas -j "$BUILD_JOBS" CC=gcc FC=gfortran \
    DYNAMIC_ARCH=1 DYNAMIC_OLDER=1 TARGET="$baseline" USE_OPENMP=1 \
    INTERFACE64=0 NO_STATIC=1 NUM_THREADS=128 COMMON_OPT=-O3
make -C /tmp/openblas install PREFIX=/opt/openblas NO_STATIC=1
mkdir -p /opt/openblas/share/licenses
cp /tmp/openblas/LICENSE /opt/openblas/share/licenses/OpenBLAS-LICENSE
rm -rf /tmp/openblas /tmp/openblas.tar.gz
BLAS

# Einsums uses HDF5 for the MP2-F12 disk implementation.
RUN apt-get update && apt-get install -y --no-install-recommends libhdf5-dev \
    && rm -rf /var/lib/apt/lists/*

# Change this single default (or use --build-arg MAX_AM_ERI=7) for higher AM.
# Psi4 selects generated Libint 5-4-3-6-5-4 for <=5, and 7-7-4-12-7-5 for 6/7.
# These are integral-class/derivative-specific limits, not a uniform AM limit.
# Values above 7 require Psi4's custom Libint generator configuration.
ARG MAX_AM_ERI=5
# Portable instruction sets with explicit tuning; never auto-detect an emulated
# build CPU. -O3 enables vectorisation without unsafe -ffast-math assumptions.
# For Apple-only deployment: ARM64_MARCH=armv8.4-a ARM64_MTUNE=apple-m1.
# For ARM servers: set ARM64_MTUNE=neoverse-n1 (or your processor).
# AMD64 defaults to x86-64-v2; AVX2/FMA deployments can use x86-64-v3.
# OpenBLAS independently dispatches AVX2/AVX512 kernels on capable CPUs.
ARG ARM64_MARCH=armv8-a
ARG ARM64_MTUNE=apple-m1
ARG AMD64_MARCH=x86-64-v2
ARG AMD64_MTUNE=generic
ENV BOOST_ROOT=/opt/boost \
    MATH_ROOT=/opt/openblas \
    CMAKE_BUILD_PARALLEL_LEVEL=${BUILD_JOBS}

# Copy the prepared source. Refresh the Git index after Docker copies the files.
ARG PSI4_REVISION
WORKDIR /src
COPY --from=source /src/ /src/
RUN git update-index --refresh || test "$?" -eq 1

# Build upstream dependencies and Psi4 through the supported CMake superbuild.
# Shared libraries keep the final image small; their full runtime closure is
# assembled below. Disable host autodetection for portable multi-arch images.
RUN <<'BUILD'
set -eu
case "$TARGETARCH" in
    arm64) cpu_flags="-march=$ARM64_MARCH -mtune=$ARM64_MTUNE" ;;
    amd64) cpu_flags="-march=$AMD64_MARCH -mtune=$AMD64_MTUNE" ;;
    *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
flags="-O3 -DNDEBUG -fPIC $cpu_flags"
cmake -S /src -B /build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/psi4 \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="$flags" \
    -DCMAKE_CXX_FLAGS="$flags" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-O1,--as-needed,-z,relro,-z,now" \
    -DCMAKE_PREFIX_PATH="/opt/boost;/opt/openblas;/opt/eigen;$(python -m pybind11 --cmakedir)" \
    -DEigen3_DIR=/opt/eigen/share/eigen3/cmake \
    -DBOOST_ROOT=/opt/boost \
    -DPython_EXECUTABLE=/opt/venv/bin/python \
    -DBLAS_TYPE=OPENBLAS -DLAPACK_TYPE=OPENBLAS \
    -DENABLE_XHOST=OFF -DENABLE_OPENMP=ON \
    -DENABLE_Einsums=ON \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
    -DMAX_AM_ERI="$MAX_AM_ERI" \
    -DCMAKE_INSIST_FIND_PACKAGE_pybind11=ON \
    -DCMAKE_INSIST_FIND_PACKAGE_qcelemental=ON \
    -DCMAKE_INSIST_FIND_PACKAGE_qcengine=ON \
    -DCMAKE_INSIST_FIND_PACKAGE_optking=ON
BUILD

# Cache completed superbuild dependencies using normal Docker layers. Psi4's
# CMake configuration still selects and builds all integral-library versions.
RUN cmake --build /build --target libint2_external libxc_external gau2grid_external --parallel "$BUILD_JOBS"
RUN pybind11_DIR="$(python -m pybind11 --cmakedir)" \
    cmake --build /build --target einsums_external --parallel "$BUILD_JOBS"

# Psi4 also uses <eigen3/Eigen/...>, which needs Eigen's parent include directory.
# Core unity compilations can each use several GB; allow separate concurrency.
ARG PSI4_BUILD_JOBS=1
ENV CPLUS_INCLUDE_PATH=/opt/eigen/include \
    CMAKE_BUILD_PARALLEL_LEVEL=${PSI4_BUILD_JOBS}
RUN <<'INSTALL'
set -eu
cmake --build /build --target install --parallel "$PSI4_BUILD_JOBS"
mkdir -p /opt/psi4/share/container
uv pip freeze --python /opt/venv/bin/python > /opt/psi4/share/container/python-requirements.txt
dpkg-query -W > /opt/psi4/share/container/build-packages.txt
for library in libint2 libxc gau2grid einsums; do
    mkdir -p "/opt/psi4/share/container/licenses/$library"
    find "/build/external/upstream/$library" -maxdepth 4 -type f \
        \( -name 'COPYING*' -o -name 'LICENSE*' -o -name 'CITATION*' \) \
        -exec cp '{}' "/opt/psi4/share/container/licenses/$library/" \;
done
printf '%s\n' "PSI4_REVISION=$PSI4_REVISION" "TARGETARCH=$TARGETARCH" "MAX_AM_ERI=$MAX_AM_ERI" \
    > /opt/psi4/share/container/build-options.txt
INSTALL

# Make the installed libraries available to the dependency inspection below.
ENV LD_LIBRARY_PATH=/opt/psi4/lib:/opt/openblas/lib:/usr/local/lib64:/usr/local/lib

# Construct a clean filesystem tree instead of copying the build environment.
# Keep licence and distribution metadata; discard headers, CMake, test data,
# static archives, package installers, and compiler-only Python dependencies.
RUN uv pip uninstall --python /opt/venv/bin/python pybind11 setuptools pytest cmake ninja && \
    rm -rf /opt/psi4/include /opt/psi4/share/cmake /opt/psi4/lib/cmake /opt/psi4/share/psi4/samples && \
    find /opt/psi4 /opt/venv -type f \( -name '*.a' -o -name '*.la' \) -delete && \
    find /opt/psi4 /opt/venv -type d \( -name __pycache__ -o -name tests \) -prune -exec rm -rf '{}' + && \
    find /opt/psi4 /opt/venv -type f -name '*.so*' -exec strip --strip-unneeded '{}' +

# Inspect every ELF object, including optional stdlib/NumPy/SciPy modules, so
# runtime libraries aren't guessed from a hand-maintained architecture list.
# Distroless supplies glibc and the ELF loader; copy other libraries separately.
RUN /usr/local/bin/python <<'ASSEMBLE'
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path('/runtime')
stdlib = Path('/usr/local/lib') / f'python{sys.version_info.major}.{sys.version_info.minor}'
for source in (Path('/opt/psi4'), Path('/opt/venv'), stdlib):
    shutil.copytree(source, root / source.relative_to('/'), symlinks=True)
runtime_stdlib = root / stdlib.relative_to('/')
for name in ('site-packages', 'ensurepip', 'idlelib', 'tkinter', 'turtledemo'):
    shutil.rmtree(runtime_stdlib / name, ignore_errors=True)
for directory in runtime_stdlib.glob('config-*'):
    shutil.rmtree(directory)
for extension in runtime_stdlib.glob('lib-dynload/_tkinter*.so'):
    extension.unlink()
bin_dir = root / 'usr/local/bin'
bin_dir.mkdir(parents=True)
exe = Path(sys.executable).resolve()
shutil.copy2(exe, bin_dir / exe.name)
for name in ('python', 'python3'):
    (bin_dir / name).symlink_to(exe.name)
for lib in Path('/usr/local/lib').glob('libpython*.so*'):
    shutil.copy2(lib, root / 'usr/local/lib' / lib.name, follow_symlinks=False)

glibc = {'libc.so.6', 'libm.so.6', 'libdl.so.2', 'libpthread.so.0',
         'librt.so.1', 'libresolv.so.2', 'libutil.so.1'}
libdir = root / 'opt/runtime/lib'
libdir.mkdir(parents=True)
for file in list(root.rglob('*')):
    if not file.is_file() or file.is_symlink():
        continue
    with file.open('rb') as stream:
        if stream.read(4) != b'\x7fELF':
            continue
    original = Path('/') / file.relative_to(root)
    result = subprocess.run(['ldd', str(original)], capture_output=True, text=True)
    if 'not found' in result.stdout:
        raise RuntimeError(f'Missing build library for {original}: {result.stdout}')
    for match in re.finditer(r'=> (/\S+)', result.stdout):
        source = Path(match.group(1))
        if source.name in glibc or (root / source.relative_to('/')).exists():
            continue
        shutil.copy2(source, libdir / source.name, follow_symlinks=True)
for path in ('work', 'tmp'):
    directory = root / path
    directory.mkdir(exist_ok=True)
    directory.chmod(0o1777)
shutil.copy2('/src/COPYING', root / 'opt/psi4/share/container/COPYING')
shutil.copy2('/src/COPYING.LESSER', root / 'opt/psi4/share/container/COPYING.LESSER')
shutil.copy2('/opt/openblas/share/licenses/OpenBLAS-LICENSE', root / 'opt/psi4/share/container/OpenBLAS-LICENSE')
ASSEMBLE

# The final image has no shell, apt, uv, pip, compilers, or build source tree.
# Debian 13 matches the official Python builder's glibc ABI. Run without root.
FROM ${RUNTIME_IMAGE} AS runtime
ARG PSI4_REVISION
LABEL org.opencontainers.image.source="https://github.com/jasonrig/psi4" \
    org.opencontainers.image.revision="${PSI4_REVISION}"
COPY --from=build /runtime/ /
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/opt/psi4/bin:/usr/local/bin \
    PYTHONPATH=/opt/psi4/lib \
    PSIDATADIR=/opt/psi4/share/psi4 \
    LD_LIBRARY_PATH=/opt/psi4/lib:/opt/runtime/lib:/usr/local/lib \
    PSI_SCRATCH=/tmp \
    HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    OMP_NUM_THREADS=1 \
    OMP_MAX_ACTIVE_LEVELS=1 \
    OPENBLAS_NUM_THREADS=1
USER 65532:65532
# Docker's shared-memory workspace discards the smoke test's timer.dat output.
WORKDIR /dev/shm
# JSON form is essential: distroless cannot execute shell-form entrypoints.
# Set parallelism using Psi4's -n option or psi4.set_num_threads(), rather than
# assuming environment thread counts override Psi4's own thread controller.
RUN ["/opt/venv/bin/python", "-c", "import importlib.util, pathlib, subprocess, psi4; assert not any(pathlib.Path(p).exists() for p in ('/bin/sh', '/bin/bash', '/usr/bin/apt', '/usr/local/bin/uv')); assert importlib.util.find_spec('pip') is None; subprocess.run(['/opt/venv/bin/python', '/opt/psi4/bin/psi4', '--version'], check=True); print('Distroless nonroot runtime check passed:', psi4.__version__)"]
WORKDIR /work
ENTRYPOINT ["/opt/venv/bin/python", "/opt/psi4/bin/psi4"]
CMD ["--help"]
