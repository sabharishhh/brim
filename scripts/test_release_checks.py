import hashlib
import os
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

    def test_disk_image_uses_gatekeeper_primary_signature_context(self):
        # Without the disk-image context, Gatekeeper can reject a valid DMG.
        # Stop at the assessment so this test never mounts or opens anything.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "Brim-1.0.dmg"
            package.write_bytes(b"test package")
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            package.with_suffix(".dmg.sha256").write_text(f"{digest}  {package.name}\n")
            commands = root / "commands"
            commands.mkdir()
            for name in ("codesign", "xcrun"):
                command = commands / name
                command.write_text("#!/bin/sh\nexit 0\n")
                command.chmod(0o755)
            assessment = commands / "spctl"
            assessment.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "args = sys.argv[1:]\n"
                "if '--context' not in args or "
                "args[args.index('--context') + 1] != 'context:primary-signature':\n"
                "    sys.exit('Missing disk-image assessment context')\n"
                "print('Disk-image assessment reached', file=sys.stderr)\n"
                "sys.exit(73)\n"
            )
            assessment.chmod(0o755)
            result = subprocess.run(
                ["bash", str(Path(__file__).with_name("verify_release.sh")),
                 "v1.0", directory, "a" * 40],
                env={**os.environ, "PATH": f"{commands}{os.pathsep}{os.environ['PATH']}"},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertIn("Disk-image assessment reached", result.stderr)


if __name__ == "__main__":
    unittest.main()
