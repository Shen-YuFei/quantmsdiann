"""Exercise the DIA-NN modules' flag extraction with Nextflow's strict Bash flags."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


MODULES = (
    "preliminary_analysis",
    "assemble_empirical_library",
    "individual_analysis",
    "final_quantification",
    "fine_tune_models",
)
MODULE_ROOT = Path(__file__).resolve().parents[1] / "modules" / "local" / "diann"


class DiannModificationFlagsTest(unittest.TestCase):
    def run_extraction(self, module, config):
        source = (MODULE_ROOT / module / "main.nf").read_text()
        # Render just the module's shell assignment, without requiring DIA-NN or RAW files.
        assignment = next(
            line.strip() for line in source.splitlines() if line.strip().startswith("mod_flags=")
        )
        assignment = assignment.replace("${diann_config}", "${DIANN_CONFIG}")
        assignment = assignment.replace("\\\\", "\\").replace("\\$", "$")
        return subprocess.run(
            ["bash", "-e", "-u", "-o", "pipefail", "-c", assignment + '\nprintf "%s" "$mod_flags"'],
            env={**os.environ, "DIANN_CONFIG": str(config)},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_no_modifications(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "diann config.cfg"
            for content in ("", "--cut K*,R*,!*P --mass-acc-ms1 15.0 --mass-acc 15.0\n"):
                config.write_text(content)
                for module in MODULES:
                    with self.subTest(module=module, content=content):
                        result = self.run_extraction(module, config)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, "")

    def test_modifications_and_channels_are_preserved(self):
        flags = (
            "--fixed-mod UniMod:4,57.021464,C",
            "--var-mod UniMod:35,15.994915,M",
            "--monitor-mod UniMod:21,79.966331,STY",
            "--lib-fixed-mod UniMod:4",
            "--original-mods",
            "--channels SILAC,L,KR,0:0; SILAC,H,KR,8.014199:10.008269",
        )
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "diann config.cfg"
            for separator in (" ", "\n"):
                config.write_text("--cut K*,R*,!*P\n" + separator.join(flags) + "\n")
                for module in MODULES:
                    with self.subTest(module=module, separator=separator):
                        result = self.run_extraction(module, config)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, " ".join(flags) + " ")

    def test_config_read_errors_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            for config in (Path(directory) / "missing.cfg", Path(directory)):
                for module in MODULES:
                    with self.subTest(module=module, config=config):
                        result = self.run_extraction(module, config)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertTrue(result.stderr)


if __name__ == "__main__":
    unittest.main()
