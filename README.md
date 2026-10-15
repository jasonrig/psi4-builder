# psi4-builder

Build Psi4 for Linux containers and native macOS. The `psi4/` submodule uses
[jasonrig/psi4](https://github.com/jasonrig/psi4), a fork of
[psi4/psi4](https://github.com/psi4/psi4).

Each builder commit records a specific Psi4 commit. The fork can advance while
the builder continues to use its recorded source revision. Build commands do
not update the submodule.

## Get the source

```sh
git clone --recurse-submodules https://github.com/jasonrig/psi4-builder.git
cd psi4-builder
```

If you already cloned the builder, initialize the submodule:

```sh
git submodule update --init --recursive
```

The files have this layout:

```text
Dockerfile                 Linux arm64 and amd64 build
Dockerfile.dockerignore     Docker source-context exclusions
build-psi4-macos.sh         Native macOS build and unsigned installer
psi4/                      Psi4 source submodule
build/                     Local build files (ignored by Git)
```

## Linux containers

Use Docker with Buildx and BuildKit. Run the commands from the builder root.
Use `./psi4` as the build context. `Dockerfile.dockerignore` applies to that
context; the builder files and local build directory stay outside it.

Build and load an arm64 image:

```sh
docker buildx build -f Dockerfile \
  --platform linux/arm64 --load -t psi4:arm64 \
  --build-arg PSI4_REVISION="$(git -C psi4 rev-parse HEAD)" ./psi4
```

For amd64, use `--platform linux/amd64` and `-t psi4:amd64`.

For multi-platform output, use a builder that supports it. To create a
`docker-container` builder, run this command once:

```sh
docker buildx create --name psi4 --driver docker-container --bootstrap
```

Build both architectures into an OCI archive with that builder:

```sh
mkdir -p build
docker buildx build --builder psi4 -f Dockerfile \
  --platform linux/arm64,linux/amd64 \
  --build-arg PSI4_REVISION="$(git -C psi4 rev-parse HEAD)" \
  --output type=oci,dest=build/psi4.oci.tar ./psi4
```

To publish both architectures, replace `--output` with
`--push -t <registry>/<image>:<tag>`. Use native builders when available.
Emulation can increase build time.

Set the maximum angular momentum with `--build-arg MAX_AM_ERI=7`, or change
the `ARG MAX_AM_ERI=5` default in the Dockerfile. Psi4 selects its integral
libraries. The generated Libint limits differ by integral and derivative type.
Values above 7 require a custom Psi4 integral configuration.

The default BLAS/LAPACK implementation is OpenBLAS with runtime CPU detection.
The Dockerfile lists the instruction-set and CPU tuning defaults. Use
`--build-arg BUILD_JOBS=N` for dependency jobs and
`--build-arg PSI4_BUILD_JOBS=N` for Psi4 jobs. Each Psi4 job can use several GB
of memory.

Run a calculation in the current directory:

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/work" psi4:arm64 -i input.dat -n 4
```

Run the Python API:

```sh
docker run --rm --entrypoint /opt/venv/bin/python \
  psi4:arm64 -c 'import psi4; print(psi4.__version__)'
```

The final image uses a distroless base and a non-root user. It has no shell,
compiler, package manager, or build source. The image includes runtime libraries
and license notices. Linux containers cannot use macOS Accelerate.

The source stage obtains Git metadata for `PSI4_REVISION` and matching upstream
tags. Psi4 uses that metadata to calculate its version. Local source changes
remain in the build and can mark its version as dirty. The image revision label
and `/opt/psi4/share/container/build-options.txt` record the selected commit.
The same directory records resolved Python and operating-system packages.

## Native macOS

Install Homebrew and the Xcode Command Line Tools. Run the script without
arguments to open the terminal settings menu:

```sh
./build-psi4-macos.sh
```

The script uses `psi4/` beside the script as its default source. You can supply
another Psi4 checkout as the final argument. The script uses uv to obtain
CPython and create the Python virtual environment. It does not use Conda.

For a direct installation:

```sh
./build-psi4-macos.sh --install --python latest --non-interactive
```

For an unsigned installer:

```sh
./build-psi4-macos.sh --python latest \
  --pkg-output Psi4-unsigned.pkg --non-interactive
```

`--pkg-output` selects installer creation. This action keeps its runtime and
build virtual environment under the build directory. It does not install Psi4
in a permanent location. The installer supports one user without root access,
or all users with administrator access. The installer contains its Python
runtime and dependencies; it does not require Homebrew or uv on the destination
Mac. It is unsigned and has no Apple notarization.

Use `--package-only` to create another installer from a completed `--package`
build. Use the same Python, CPU, angular momentum, minimum macOS version, and
build directory as that build.

Use `--help` for all options. Each setting is also available in the menu.
`--python` accepts `latest`, an available CPython version, or an executable
path. A version can omit its minor or patch number. It must meet the Python
requirement in the selected Psi4 source.

The `auto` CPU setting uses Clang to detect the CPU. It checks the detected
M-series family against the hardware. Use `--cpu portable` for other CPU
generations of the same architecture. Apple Clang, Homebrew libomp, and the
LP64 Accelerate interface provide the native compiler and mathematics support.

Default paths:

- Build files: `<start-directory>/build/<profile>`
- Direct installation: `~/.local/psi4-accelerate/<profile>`
- Installer build environment: `<build-directory>/runtime`
- Installer file: `<start-directory>/Psi4-<bundle>-unsigned.pkg`

The profile identifies the Python version, CPU target, angular momentum, and
minimum macOS version. Use `--build-dir`, `--install-dir`, and `--pkg-output`
to change the applicable paths. `--install-dir` applies only to direct
installation. The script shows resolved paths before the build starts.

Builds update Homebrew and the required build tools by default. Use
`--no-update-tools` to retain installed tool versions. Missing tools are still
installed. Psi4 selects Libint and Libxc; the builders do not override their
versions.

You can remove a completed build directory to recover disk space. A direct
installation and an installed package work independently of that directory.
Keep the build directory if you want to use `--package-only` or an incremental
build. Use a new build directory when you change a custom Python installation.

## Update the tested source

Start with a clean submodule. Fetch the fork and select a candidate commit:

```sh
git -C psi4 fetch origin
git -C psi4 checkout --detach <commit>
```

Build and validate the required systems. Then commit the submodule reference
with any builder changes:

```sh
git add psi4 Dockerfile Dockerfile.dockerignore build-psi4-macos.sh README.md
git commit -m "Validate builders with the selected Psi4 revision"
```

Tag a validated builder commit to identify that builder/source combination.
Use release assets for installer packages and container archives. Keep generated
files out of Git.

The initial source revision is `60c9b2a773c05abc26991c5ed48cf9862cdb4978`
(Psi4 `1.12a1.dev43`). The original builds passed Linux arm64 and amd64
chemistry checks, and native Apple M1 Pro checks with CPython 3.15.0,
Accelerate, and `MAX_AM_ERI=5`. The native installer also passed installation
for one user without root access.

The source revision and Docker image digests are fixed. Compatible Python
dependencies can advance, and native build tools can update. A validated
builder commit records a tested recipe; a later rebuild can resolve different
dependencies. Retain dependency and compiler version records with release
artifacts when you need to identify the exact environment.

Psi4 and its dependencies retain their own licenses. See the source and the
license notices included in each generated runtime.
