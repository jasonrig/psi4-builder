# psi4-builder

Build Psi4 as a distroless Linux container or a native macOS installation with
Accelerate. The `psi4/` submodule uses [jasonrig/psi4](https://github.com/jasonrig/psi4).
Each builder commit records its source revision, so the fork can advance independently.

## Get the source

```sh
git clone --recurse-submodules https://github.com/jasonrig/psi4-builder.git
cd psi4-builder
```

For an existing clone, run `git submodule update --init --recursive`.
Build commands do not update the submodule.

## Linux containers

Use Docker with Buildx and BuildKit. Run these commands from the repository root;
`./psi4` is the build context.

Build and load an arm64 image:

```sh
docker buildx build -f Dockerfile \
  --platform linux/arm64 --load -t psi4-arm64 \
  --build-arg PSI4_REVISION="$(git -C psi4 rev-parse HEAD)" ./psi4
```

For amd64, use `--platform linux/amd64` and `-t psi4-amd64`.
For both architectures, create a container builder once, then export an OCI archive:

```sh
docker buildx create --name psi4 --driver docker-container --bootstrap
mkdir -p build
docker buildx build --builder psi4 -f Dockerfile \
  --platform linux/arm64,linux/amd64 \
  --build-arg PSI4_REVISION="$(git -C psi4 rev-parse HEAD)" \
  --output type=oci,dest=build/psi4.oci.tar ./psi4
```

Set `MAX_AM_ERI` in the Dockerfile or with `--build-arg MAX_AM_ERI=N`.
Psi4 selects Libint and Libxc. OpenBLAS provides BLAS/LAPACK with CPU detection.
The Dockerfile also lists CPU tuning options, dependency jobs (`BUILD_JOBS`), and
Psi4 jobs (`PSI4_BUILD_JOBS`). Each Psi4 job can use several GB of memory.

Run a calculation in the current directory:

```sh
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/work" psi4-arm64 -i input.dat -n 4
```

For the Python API, use `--entrypoint /opt/venv/bin/python`.
The final image runs without root and contains no shell or build tools.
Resolved dependency records are in `/opt/psi4/share/container/`.
Linux containers cannot use macOS Accelerate.

## Native macOS

Install Homebrew and the Xcode Command Line Tools. Open the settings menu with:

```sh
./build-psi4-macos.sh
```

All settings are available in the menu and through CLI options; use `--help`
for details. The source defaults to `psi4/` beside the script. To use another
checkout, supply its path as the final argument.

Build a direct installation or an unsigned installer:

```sh
./build-psi4-macos.sh --install --python latest --non-interactive
./build-psi4-macos.sh --pkg-output Psi4-unsigned.pkg --non-interactive
```

The script uses uv to obtain CPython and create a virtual environment.
`--python` accepts `latest`, an available CPython version, or an executable path.
Clang detects the CPU by default; `--cpu portable` supports other CPU generations
of the same architecture. Native builds use Accelerate and Homebrew libomp.

| Output | Default location |
| --- | --- |
| Build files | `<start-directory>/build/<profile>` |
| Direct installation | `~/.local/psi4-accelerate/<profile>` |
| Installer build environment | `<build-directory>/runtime` |
| Installer | The start directory |

Use `--build-dir`, `--install-dir`, and `--pkg-output` to change these paths.
`--install-dir` applies only to direct installation. Installer builds keep their
runtime under the build directory and do not create a permanent installation.
The installer includes Python and dependencies. It supports one user without
root access or all users with administrator access. It has no Apple notarization.

Use `--package-only` with the same settings to package a completed installer build.
Use `--no-update-tools` to retain installed build tools. Keep the build directory
for incremental builds or packaging; installed runtimes work independently of it.

## Update the source

Start with a clean submodule, then select the source to test:

```sh
git -C psi4 fetch origin
git -C psi4 checkout --detach <source-ref>
```

Build and validate the required systems before committing the submodule reference
and any builder changes. Keep generated files out of Git. Dependencies and build
tools can advance between builds; retain resolved dependency records with artifacts
when you need to identify the exact build environment.

Psi4 and its dependencies retain their own licenses. See the source and the
license notices included in each generated runtime.
