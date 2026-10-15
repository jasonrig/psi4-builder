#!/usr/bin/env python3
"""Compare native Psi4 builds with fresh, sequential calculation processes."""

from __future__ import annotations

import argparse
import csv
import hashlib
import itertools
import json
import math
import os
import platform
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

CASES = ("hf", "dft", "mp2")
ENERGY_TOLERANCE = 1e-8  # Hartree; compare each run with a baseline warm-up.
MIN_REPEATS = 3
HEADERS = (
    "variant",
    "case",
    "threads",
    "blas",
    "wait",
    "repeat",
    "energy_hartree",
    "compute_seconds",
    "correlation_seconds",
    "wall_seconds",
    "max_rss_bytes",
    "basis_functions",
    "energy_error_hartree",
    "scf_iterations",
)
_BOOTSTRAP = (
    "import runpy,sys; sys.path.insert(0,sys.argv.pop(1)); "
    "runpy.run_path(sys.argv.pop(1),run_name='__main__')"
)


@dataclass(frozen=True)
class Measurement:
    """Store the numerical result and the calculation times.

    Attributes:
        energy: Total molecular energy, in Hartree.
        compute: Time inside the energy calls, in seconds, including HF for MP2.
        correlation: MP2 correlation time, in seconds; zero for HF and DFT.
        basis_functions: Number of orbital basis functions.
        iterations: Number of SCF iterations before convergence.
    """

    energy: float
    compute: float
    correlation: float
    basis_functions: int
    iterations: int


def parse_measurement(stdout: str, case: str) -> Measurement:
    """Read result markers from stdout, without matching the echoed input.

    Args:
        stdout: Standard output from a successful Psi4 process.
        case: Calculation name: hf, dft, or mp2.

    Returns:
        The energy, calculation times, and basis size.

    Raises:
        ValueError: A result is missing, non-finite, or has an invalid time.
    """
    match = re.search(r"^BENCHMARK_RESULT (\S+) (\S+) (\d+)$", stdout, re.MULTILINE)
    if match is None:
        raise ValueError("Psi4 did not write a benchmark result.")
    energy, elapsed = float(match[1]), float(match[2])
    correlation = 0.0
    if case == "mp2":
        reference = re.search(
            r"^BENCHMARK_REFERENCE (\S+) (\S+)$", stdout, re.MULTILINE
        )
        if reference is None:
            raise ValueError("MP2 did not write the HF reference time.")
        correlation = elapsed
        elapsed += float(reference[2])
    if not math.isfinite(energy) or not math.isfinite(elapsed) or elapsed <= 0:
        raise ValueError("Psi4 returned an invalid energy or calculation time.")
    iterations = re.search(r"^BENCHMARK_ITERATIONS (\d+)$", stdout, re.MULTILINE)
    if iterations is None:
        raise ValueError("Psi4 did not write its SCF iteration count.")
    return Measurement(energy, elapsed, correlation, int(match[3]), int(iterations[1]))


def energy_error(energy: float, reference: float) -> float:
    """Check energy agreement and return the absolute error in Hartree.

    Args:
        energy: Energy from the current run.
        reference: Energy from the baseline warm-up.

    Returns:
        Absolute energy difference.

    Raises:
        ValueError: The energy difference exceeds the benchmark tolerance.
    """
    error = abs(energy - reference)
    if not math.isfinite(error) or error > ENERGY_TOLERANCE:
        raise ValueError(f"Energy differs from the baseline by {error:.3g} Hartree.")
    return error


class _Options(argparse.Namespace):
    action: str
    baseline_build: Path
    build_root: Path
    output: Path
    variants: str
    cases: str
    threads: str
    blas: str
    wait: str
    repeats: int
    timeout: int
    seed: int


def _arguments() -> _Options:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    run = commands.add_parser(
        "run",
        help="Run warm-ups and the measurement matrix",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    run.add_argument(
        "--baseline-build",
        type=Path,
        required=True,
        default=argparse.SUPPRESS,
        help="Directory of a completed native --package build",
    )
    run.add_argument(
        "--build-root",
        type=Path,
        default=Path("build/performance"),
        help="Directory containing the full and thin build variants",
    )
    run.add_argument(
        "--output",
        type=Path,
        required=True,
        default=argparse.SUPPRESS,
        help="New result directory",
    )
    run.add_argument(
        "--variants",
        default="baseline,full,thin",
        help="Comma-separated build names: baseline, full, thin",
    )
    run.add_argument(
        "--cases",
        default=",".join(CASES),
        help="Comma-separated calculations: hf, dft, mp2",
    )
    run.add_argument(
        "--threads",
        default="auto",
        help="Comma-separated Psi4/OpenMP counts; auto uses 1, half/all "
        "performance cores, and all CPU cores",
    )
    run.add_argument(
        "--blas",
        default="auto,1",
        help="Comma-separated Accelerate thread caps: positive integers and/or auto "
        "for library defaults; independent of --threads",
    )
    run.add_argument(
        "--wait", default="default,passive", help="OpenMP default and/or passive"
    )
    run.add_argument(
        "--repeats", type=int, default=3, help="Measured repeats; at least three"
    )
    run.add_argument(
        "--timeout", type=int, default=180, help="Time limit per run, in seconds"
    )
    run.add_argument("--seed", type=int, default=4107, help="Seed for run order")
    summary = commands.add_parser(
        "summarise", help="Rebuild summary files from raw results"
    )
    summary.add_argument("output", type=Path)
    return parser.parse_args(namespace=_Options())


def _command_output(command: list[str]) -> str:
    # Commands use argument lists. Shell expansion is disabled.
    return subprocess.check_output(command, text=True).strip()  # noqa: S603


def _choices(value: str, allowed: tuple[str, ...]) -> list[str]:
    values = value.split(",")
    if len(set(values)) != len(values) or any(item not in allowed for item in values):
        raise ValueError(f"Use distinct values: {', '.join(allowed)}.")
    return values


def _thread_counts(value: str) -> list[int]:
    if value == "auto":
        total = os.cpu_count() or 1
        performance = int(
            _command_output(["/usr/sbin/sysctl", "-n", "hw.perflevel0.physicalcpu"])
        )
        return sorted({1, max(1, performance // 2), performance, total})
    counts = [int(item) for item in value.split(",")]
    if not counts or min(counts) < 1 or len(set(counts)) != len(counts):
        raise ValueError("Thread counts must be distinct positive integers.")
    return counts


def blas_caps(value: str) -> list[str]:
    """Read independent Accelerate thread caps.

    Args:
        value: Comma-separated positive integers and/or auto.

    Returns:
        Distinct settings, with auto selecting Accelerate defaults.

    Raises:
        ValueError: A cap is invalid or appears more than once.
    """
    values = value.split(",")
    if len(set(values)) != len(values) or any(
        item != "auto" and re.fullmatch(r"[1-9][0-9]*", item) is None for item in values
    ):
        raise ValueError("BLAS caps must be distinct positive integers and/or auto.")
    return values


def benchmark_environment(blas: str, wait: str) -> dict[str, str]:
    """Set thread controls before a new calculation process starts.

    Args:
        blas: Accelerate thread cap, or auto to remove the cap.
        wait: OpenMP wait profile: default or passive.

    Returns:
        Process environment with inherited thread controls removed.
    """
    env = os.environ.copy()
    # Remove inherited settings so each matrix entry has explicit thread settings.
    for name in tuple(env):
        if name.startswith(("OMP_", "KMP_", "GOMP_", "MKL_", "OPENBLAS_", "VECLIB_")):
            del env[name]
    for name in ("PYTHONHOME", "PYTHONPATH", "PSIDATADIR"):
        env.pop(name, None)
    env.update(
        OMP_DYNAMIC="FALSE", OMP_MAX_ACTIVE_LEVELS="1", PYTHONDONTWRITEBYTECODE="1"
    )
    if blas != "auto":
        env["VECLIB_MAXIMUM_THREADS"] = blas
    if wait == "passive":
        env.update(OMP_WAIT_POLICY="passive", KMP_BLOCKTIME="0")
    return env


def _runtime(args: _Options, variant: str) -> Path:
    if variant == "baseline":
        return args.baseline_build.resolve() / "runtime"
    return args.build_root.resolve() / variant / "runtime"


def _source_directory(baseline_build: Path) -> Path:
    for line in (baseline_build / "CMakeCache.txt").read_text().splitlines():
        if line.startswith("CMAKE_HOME_DIRECTORY:INTERNAL="):
            return Path(line.partition("=")[2])
    raise ValueError("The baseline does not record its source directory.")


def _assert_no_builds() -> None:
    tools = {
        "clang",
        "clang++",
        "gcc",
        "g++",
        "gfortran",
        "ld",
        "ld64",
        "ld64.lld",
        "lld",
        "ninja",
        "make",
        "cmake",
    }
    active = {
        Path(command).name
        for command in _command_output(["/bin/ps", "-A", "-o", "comm="]).splitlines()
        if Path(command).name in tools
    }
    if active:
        raise ValueError(
            "Finish all build processes before benchmarking: "
            f"{', '.join(sorted(active))}"
        )


def _measure(
    args: _Options,
    setting: tuple[str, str, int, str, str],
    repeat: int,
) -> tuple[Measurement, float, int]:
    variant, case, threads, blas, wait = setting
    _assert_no_builds()
    baseline = args.baseline_build.resolve() / "runtime"
    runtime = _runtime(args, variant)
    name = f"{variant}-{case}-t{threads}-blas{blas}-wait{wait}-r{repeat}"
    log = args.output.resolve() / "logs" / name
    with tempfile.TemporaryDirectory(
        prefix=f"{name}-", dir=args.output / "scratch"
    ) as scratch:
        command = [
            str(baseline / "venv/bin/python"),
            "-I",
            "-c",
            _BOOTSTRAP,
            str(runtime / "lib"),
            str(baseline / "bin/psi4-driver"),
            "-i",
            str(Path(__file__).with_name(f"{case}.dat").resolve()),
            "-o",
            str(log.with_suffix(".out")),
            "-s",
            scratch,
            "-n",
            str(threads),
        ]
        start = time.perf_counter()
        with (
            log.with_suffix(".stdout").open("w") as stdout,
            log.with_suffix(".stderr").open("w") as stderr,
        ):
            subprocess.run(  # noqa: S603 -- Local tools and explicit argument lists.
                command,
                cwd=scratch,
                env=benchmark_environment(blas, wait),
                stdout=stdout,
                stderr=stderr,
                timeout=args.timeout,
                check=True,
            )
        wall = time.perf_counter() - start
    _assert_no_builds()
    measurement = parse_measurement(log.with_suffix(".stdout").read_text(), case)
    core = re.search(
        r"^BENCHMARK_CORE (.+)$", log.with_suffix(".stdout").read_text(), re.MULTILINE
    )
    if core is None or not Path(core[1]).resolve().is_relative_to(
        (runtime / "lib/psi4").resolve()
    ):
        raise ValueError(f"Psi4 did not load the selected build: {runtime}")
    rss = re.search(
        r"^BENCHMARK_RSS (\d+)$", log.with_suffix(".stdout").read_text(), re.MULTILINE
    )
    if rss is None:
        raise ValueError(f"Missing memory measurement: {log}")
    return measurement, wall, int(rss[1])


def summarise(output: Path) -> None:
    """Write timing statistics from measured rows in results.csv.

    Args:
        output: Directory with the raw benchmark CSV. Warm-up rows are excluded.
    """
    groups: dict[tuple[str, ...], list[list[str]]] = {}
    with (output / "results.csv").open(newline="") as stream:
        reader = csv.reader(stream)
        next(reader)
        for row in reader:
            if int(row[5]) > 0:
                groups.setdefault(tuple(row[:5]), []).append(row)
    headers = [
        "variant",
        "case",
        "threads",
        "blas",
        "wait",
        "runs",
        "median_seconds",
        "mean_seconds",
        "stdev_seconds",
        "cv_percent",
        "min_seconds",
        "max_seconds",
        "median_wall_seconds",
        "median_correlation_seconds",
        "max_energy_error_hartree",
        "speedup_vs_baseline",
        "min_scf_iterations",
        "max_scf_iterations",
    ]
    medians = {
        key: statistics.median(float(row[7]) for row in rows)
        for key, rows in groups.items()
    }
    report = [
        "# Native Psi4 benchmark results",
        "",
        "Times are seconds inside the calculation calls. "
        "MP2 includes its HF reference.",
        "Warm-ups are excluded. Each process has a new scratch directory.",
        "Psi4/OpenMP is the requested `psi4 -n` count. Accelerate cap is "
        "`VECLIB_MAXIMUM_THREADS`; auto leaves it unset. These are independent "
        "controls. Accelerate can use fewer workers than its cap. "
        "The columns do not report total process thread counts.",
        "",
        "| Build | Calculation | Psi4/OpenMP | Accelerate cap | Wait | Runs | "
        "Median (s) | CV (%) | Speedup* |",
        "| --- | --- | ---: | --- | --- | ---: | ---: | ---: | ---: |",
    ]
    with (output / "summary.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(headers)
        for key, rows in sorted(groups.items()):
            times = [float(row[7]) for row in rows]
            mean = statistics.mean(times)
            deviation = statistics.stdev(times) if len(times) > 1 else 0.0
            median = medians[key]
            baseline = medians.get(("baseline", *key[1:]))
            speedup = baseline / median if baseline is not None else 0.0
            cv = 100 * deviation / mean
            record: list[str | int | float] = [
                *key,
                len(rows),
                median,
                mean,
                deviation,
                cv,
                min(times),
                max(times),
                statistics.median(float(row[9]) for row in rows),
                statistics.median(float(row[8]) for row in rows),
                max(float(row[12]) for row in rows),
                speedup,
                min(int(row[13]) for row in rows),
                max(int(row[13]) for row in rows),
            ]
            writer.writerow(record)
            report.append(
                f"| {' | '.join(key)} | {len(rows)} | {median:.3f} | "
                f"{cv:.1f} | {speedup:.3f} |"
            )
    report.extend(
        [
            "",
            "*Speedup compares the same calculation and thread settings "
            "with the baseline.",
            "CV is sample standard deviation divided by the mean. "
            "Small timing differences within",
            "the observed variation do not establish a performance improvement.",
            "",
        ]
    )
    (output / "report.md").write_text("\n".join(report))


def _run(args: _Options) -> None:
    if args.repeats < MIN_REPEATS or args.timeout < 1:
        raise ValueError("Use at least three repeats and a positive timeout.")
    variants = _choices(args.variants, ("baseline", "full", "thin"))
    cases = _choices(args.cases, CASES)
    counts = _thread_counts(args.threads)
    blas_modes = blas_caps(args.blas)
    wait_modes = _choices(args.wait, ("default", "passive"))
    if "baseline" not in variants:
        raise ValueError("Include baseline to check energies and compare timings.")
    for variant in variants:
        runtime = _runtime(args, variant)
        if not list((runtime / "lib/psi4").glob("core*.so")):
            raise ValueError(f"Missing completed runtime: {runtime}")
    _assert_no_builds()
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "logs").mkdir()
    (args.output / "scratch").mkdir()
    metadata = {
        "started_utc": datetime.now(UTC).isoformat(),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "source": _command_output(
            [
                "git",
                "-C",
                str(_source_directory(args.baseline_build)),
                "rev-parse",
                "HEAD",
            ]
        ),
        "cpu": _command_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
        "threads": counts,
        "blas": blas_modes,
        "wait": wait_modes,
        "repeats": args.repeats,
        "energy_tolerance_hartree": ENERGY_TOLERANCE,
        "seed": args.seed,
        "baseline_build": str(args.baseline_build.resolve()),
        "build_root": str(args.build_root.resolve()),
        "core_sha256": {
            variant: hashlib.sha256(
                next(
                    (_runtime(args, variant) / "lib/psi4").glob("core*.so")
                ).read_bytes()
            ).hexdigest()
            for variant in variants
        },
        "dependency_sha256": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((args.baseline_build / "runtime/lib").glob("*.dylib"))
        },
        "inputs_sha256": {
            case: hashlib.sha256(
                Path(__file__).with_name(f"{case}.dat").read_bytes()
            ).hexdigest()
            for case in cases
        },
        "compiler": _command_output(["xcrun", "clang", "--version"]),
        "power": _command_output(["/usr/bin/pmset", "-g", "batt"]),
        "thermal": _command_output(["/usr/bin/pmset", "-g", "therm"]),
        "packages": _command_output(
            [
                "uv",
                "pip",
                "freeze",
                "--python",
                str(args.baseline_build.resolve() / "runtime/venv/bin/python"),
            ]
        ),
    }
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    matrix = list(itertools.product(variants, cases, counts, blas_modes, wait_modes))
    print(
        f"Matrix: {len(matrix)} configurations, "
        f"{len(matrix) * args.repeats} measured runs",
        flush=True,
    )
    references: dict[str, float] = {}
    with (args.output / "results.csv").open("x", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(HEADERS)
        # Warm each build and case once. Baseline runs supply the reference energies.
        warmup_variants = [
            "baseline",
            *(variant for variant in variants if variant != "baseline"),
        ]
        warmups = [
            (
                variant,
                case,
                min((abs(count - 4), count) for count in counts)[1],
                "1",
                "default",
            )
            for variant in warmup_variants
            for case in cases
        ]
        for repeat in range(args.repeats + 1):
            order = warmups.copy() if repeat == 0 else matrix.copy()
            if repeat:
                # Use a fixed seed to reproduce the non-cryptographic run order.
                random.Random(args.seed + repeat).shuffle(order)  # noqa: S311
            for variant, case, threads, blas, wait in order:
                measurement, wall, rss = _measure(
                    args, (variant, case, threads, blas, wait), repeat
                )
                if repeat == 0 and variant == "baseline":
                    references[case] = measurement.energy
                error = energy_error(measurement.energy, references[case])
                record: list[str | int | float] = [
                    variant,
                    case,
                    threads,
                    blas,
                    wait,
                    repeat,
                    measurement.energy,
                    measurement.compute,
                    measurement.correlation,
                    wall,
                    rss,
                    measurement.basis_functions,
                    error,
                    measurement.iterations,
                ]
                writer.writerow(record)
                stream.flush()
                print(
                    f"r{repeat} {variant:8} {case:3} t={threads:2} "
                    f"blas={blas:4} wait={wait:7} "
                    f"{measurement.compute:8.3f}s error={error:.1e}",
                    flush=True,
                )
            summarise(args.output)
    print(f"Results: {args.output.resolve() / 'report.md'}", flush=True)


def main() -> None:
    """Run a benchmark matrix or summarise an existing result directory."""
    args = _arguments()
    try:
        if args.action == "summarise":
            summarise(args.output)
        else:
            _run(args)
    except (ValueError, FileExistsError, subprocess.SubprocessError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
