"""Check benchmark parsing, numerical validation, and timing summaries."""

import csv
import tempfile
import unittest
from pathlib import Path

import run
from run import HEADERS, energy_error, parse_measurement, summarise


class BenchmarkTests(unittest.TestCase):
    """Check the benchmark's result handling without running chemistry."""

    def test_independent_blas_caps(self) -> None:
        """Accept independent BLAS caps and apply each before process startup."""
        expected: list[str] = ["auto", "1", "2", "4", "8", "10"]
        self.assertEqual(run.blas_caps("auto,1,2,4,8,10"), expected)
        self.assertEqual(
            run.benchmark_environment("4", "passive")["VECLIB_MAXIMUM_THREADS"], "4"
        )
        self.assertNotIn(
            "VECLIB_MAXIMUM_THREADS", run.benchmark_environment("auto", "default")
        )
        for invalid in ("0", "-1", "1,1", "auto,auto", "other", "01"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                run.blas_caps(invalid)

    def test_mp2_includes_reference_time(self) -> None:
        """Include HF in total MP2 time and preserve the correlation time."""
        result = parse_measurement(
            "BENCHMARK_REFERENCE -230.0 2.0\nBENCHMARK_RESULT -231.0 3.5 570\n"
            "BENCHMARK_ITERATIONS 8\n",
            "mp2",
        )
        self.assertEqual(result.compute, 5.5)
        self.assertEqual(result.correlation, 3.5)
        self.assertEqual(result.basis_functions, 570)

    def test_missing_result_is_rejected(self) -> None:
        """Reject an echoed input line that contains no measured result."""
        with self.assertRaisesRegex(ValueError, "did not write"):
            parse_measurement("print(f'BENCHMARK_RESULT {energy}')", "hf")

    def test_energy_changes_are_rejected(self) -> None:
        """Stop a comparison when a build returns a different energy."""
        with self.assertRaisesRegex(ValueError, "differs"):
            energy_error(-230.1, -230.0)
        self.assertLess(energy_error(-230.0 + 1e-10, -230.0), 1e-8)

    def test_summary_excludes_warmup_and_matches_settings(self) -> None:
        """Use measured medians and the baseline with the same thread settings."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with (output / "results.csv").open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(HEADERS)
                for variant, blas, times in (
                    ("baseline", "1", (100, 6, 4, 5)),
                    ("thin", "1", (80, 2, 3, 2.5)),
                    ("baseline", "4", (100, 8, 9, 10)),
                    ("thin", "4", (80, 2, 3, 4)),
                ):
                    for repeat, seconds in enumerate(times):
                        record: list[str | int | float] = [
                            variant,
                            "hf",
                            4,
                            blas,
                            "default",
                            repeat,
                            -230.0,
                            seconds,
                            0,
                            seconds + 1,
                            1000,
                            114,
                            0,
                            8,
                        ]
                        writer.writerow(record)
            summarise(output)
            with (output / "summary.csv").open(newline="") as stream:
                reader = csv.reader(stream)
                fields = next(reader)
                records = [dict(zip(fields, row, strict=True)) for row in reader]
                rows = {(row["variant"], row["blas"]): row for row in records}
            baseline = rows["baseline", "1"]
            thin = rows["thin", "1"]
            baseline_fields = (baseline["runs"], baseline["median_seconds"])
            thin_fields = (thin["runs"], thin["median_seconds"])
            self.assertEqual(baseline_fields, ("3", "5.0"))
            self.assertEqual(thin_fields, ("3", "2.5"))
            self.assertEqual(thin["speedup_vs_baseline"], "2.0")
            self.assertEqual(rows["thin", "4"]["speedup_vs_baseline"], "3.0")
            self.assertEqual(baseline["min_scf_iterations"], "8")
            self.assertEqual(baseline["max_scf_iterations"], "8")
            self.assertEqual(float(baseline["median_wall_seconds"]), 6.0)
            self.assertEqual(float(baseline["max_energy_error_hartree"]), 0.0)


if __name__ == "__main__":
    unittest.main()
