# Native macOS performance tests

Build variants from a completed native `--package` build. The source tree and
baseline stay unchanged. Keep the Psi4 source at the baseline's revision.
Replace `BASELINE_BUILD` with its build directory.

```sh
./benchmarks/build-variants.sh BASELINE_BUILD
python3 benchmarks/run.py run --baseline-build BASELINE_BUILD \
  --output build/performance/results
```

The build script creates `full` and `thin` under `build/performance`. It applies
the selected LTO mode to all Psi4 core code. It keeps the baseline compiler,
CPU settings, unity builds, Python environment, and dependency libraries.
Libint, Libxc, and Gau2grid are shared with the baseline. Keep that build directory.
The variants are local test runtimes, not installer packages. Each build uses one
job by default. Optional positional arguments are output directory, job count,
and one or more variant names. Build logs and settings stay with each variant.
Each runtime provides `bin/psi4` and `bin/psi4-python`. Its small virtual
environment uses the Python packages from the baseline.

The calculations use benzene with symmetry disabled:

| Test | Method | Basis | Work measured |
| --- | --- | --- | --- |
| HF | Direct HF | cc-pVDZ | Integral generation and Fock construction |
| DFT | Density-fitted PBE0 | cc-pVTZ | Grid evaluation and hybrid exchange |
| MP2 | Density-fitted MP2, frozen core | cc-pVQZ | HF reference and correlation |

All calculations use the same geometry, convergence settings, and Psi4 memory
setting. The DFT input fixes its grid settings. MP2 also records correlation time
separately.

The default matrix compares the baseline, full LTO, and ThinLTO. Thread counts
for Psi4/OpenMP are one, half the performance cores, all performance cores, and
all CPU cores, with duplicate counts removed. It compares Accelerate's default
threading with `VECLIB_MAXIMUM_THREADS=1`, and the default OpenMP wait behaviour
with
`OMP_WAIT_POLICY=passive KMP_BLOCKTIME=0`.

`--threads` controls Psi4/OpenMP through `psi4 -n`. `--blas` independently sets
Accelerate's thread cap before each process starts. It accepts any positive
integer, or `auto` to leave the cap unset. Accelerate can use fewer workers
than its cap. These settings do not specify the total process thread count.
The runner crosses all selected values. For a wider sweep, for example:

```sh
python3 benchmarks/run.py run --baseline-build BASELINE_BUILD \
  --output build/performance/results --threads 1,4,8,10 --blas auto,1,2,4,8,10
```

Each build and calculation has an unmeasured warm-up. Each matrix entry then runs
at least three times in a fresh process and a separate scratch directory. The
runner shuffles each repeat with a recorded seed. Runs are sequential. Do not
compile or run other heavy jobs during measurements.
The runner checks for active build tools before and after each run. It stops
without accepting that measurement if a build process is present.

Use `run --help` to select builds, calculations, thread counts, threading modes,
repeat count, and timeout. The output directory must be new. The runner stops if
a run fails or an energy differs from the baseline by more than the recorded
tolerance. It removes scratch files after each run, including failed runs.

`results.csv` contains all individual measurements; repeat zero is a warm-up.
Its `threads` column records the Psi4/OpenMP count. Its `blas` column records
the independent Accelerate cap, or `auto` for library defaults.
`summary.csv` and `report.md` contain measured medians, means, sample standard
deviations, ranges, coefficients of variation, and comparisons with the baseline
at the same settings. Logs retain stdout, stderr, and Psi4 output. Metadata records
the host, compiler, source, Python packages, settings, and input checksums.

Calculation times exclude Python startup. Wall times include startup and exit.
MP2 calculation time includes its HF reference. Small differences within the
observed timing variation do not establish an improvement. Three runs are a
screening minimum; use more repeats for close comparisons.

To rebuild summaries from retained raw results:

```sh
python3 benchmarks/run.py summarise build/performance/results
```

To check the runner and shell script:

```sh
python3 -m unittest discover -s benchmarks -p test_run.py
uvx ruff check benchmarks
uvx ruff format --check benchmarks
uvx mypy --config-file benchmarks/pyproject.toml benchmarks/run.py benchmarks/test_run.py
shellcheck benchmarks/build-variants.sh
```
