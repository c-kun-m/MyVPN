from pathlib import Path
import subprocess
import tempfile
import unittest

from bootstrap import verify_vendor


class DependencyVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.original = "// swift-tools-version:5.3\n// unchanged package body\n"
        (self.root / "Package.swift").write_text(self.original)
        (self.root / "source.swift").write_text("// unchanged source\n")
        self.git("init", "-q")
        self.git("config", "core.autocrlf", "false")
        self.git("add", ".")
        self.git("-c", "user.name=Build Tool Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        self.revision = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True,
                                       stderr=subprocess.PIPE)

    def test_only_tools_version_changes_and_repeat_is_safe(self):
        verify_vendor(self.root, self.revision, apply_manifest_fix=True)
        verify_vendor(self.root, self.revision, apply_manifest_fix=True)
        verify_vendor(self.root, self.revision)
        self.assertEqual((self.root / "Package.swift").read_text(),
                         self.original.replace("5.3", "5.5", 1))
        self.assertEqual((self.root / "source.swift").read_text(), "// unchanged source\n")

    def test_manifest_tampering_is_rejected_without_overwrite(self):
        verify_vendor(self.root, self.revision, apply_manifest_fix=True)
        manifest = self.root / "Package.swift"
        tampered = manifest.read_text() + "// unexpected change\n"
        manifest.write_text(tampered)
        with self.assertRaises(ValueError):
            verify_vendor(self.root, self.revision, apply_manifest_fix=True)
        self.assertEqual(manifest.read_text(), tampered)

    def test_other_changes_and_wrong_revision_are_rejected(self):
        with self.assertRaises(ValueError):
            verify_vendor(self.root, "0" * 40, apply_manifest_fix=True)
        (self.root / "source.swift").write_text("// unexpected change\n")
        with self.assertRaises(ValueError):
            verify_vendor(self.root, self.revision, apply_manifest_fix=True)
        self.assertEqual((self.root / "Package.swift").read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
