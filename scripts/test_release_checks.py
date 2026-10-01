import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReleaseChecksTests(unittest.TestCase):
    def check_package(self, tag="v1.0", checksum=None, filename="Brim-1.0.dmg", sidecar=True):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "Brim-1.0.dmg"
            package.write_bytes(b"not a signed disk image")
            if sidecar:
                digest = checksum or hashlib.sha256(package.read_bytes()).hexdigest()
                package.with_suffix(".dmg.sha256").write_text(f"{digest}  {filename}\n")
            script = Path(__file__).with_name("verify_release.sh")
            return subprocess.run(
                ["bash", str(script), tag, directory, "a" * 40],
                capture_output=True, text=True,
            )

    def test_changed_package_is_rejected_before_mounting(self):
        result = self.check_package(checksum="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum does not match", result.stderr)

    def test_checksum_cannot_point_at_a_local_build_path(self):
        result = self.check_package(filename="/Users/developer/build/Brim-1.0.dmg")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without an absolute path", result.stderr)

    def test_missing_checksum_cannot_be_published(self):
        result = self.check_package(sidecar=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("both required", result.stderr)

    def test_tag_is_a_version_not_a_shell_expression(self):
        result = self.check_package(tag="v1.0; echo unexpected")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version tag", result.stderr)


if __name__ == "__main__":
    unittest.main()
