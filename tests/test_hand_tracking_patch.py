"""Offline checks for the pinned native patch installer; no SDK or upstream clone needed."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "tools" / "apply_hand_tracking_patch.py"
TARGET = "godotrealitykit/GodotRealityKit/RealityKit/HandAnchors.swift"


class HandTrackingPatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wisualizer-hand-patch-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.checkout = base / "plugin"
        self.checkout.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Patch fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.target = self.checkout / TARGET
        self.target.parent.mkdir(parents=True)
        self.original = "baseline native source\n"
        self.changed = "lifecycle-safe native source\n"
        self.target.write_text(self.original)
        self.git("add", ".")
        self.git("commit", "-qm", "Local baseline")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.target.write_text(self.changed)
        patch = self.git("diff", "--no-ext-diff", "--no-renames", "--binary", "HEAD", "--", TARGET).stdout
        self.target.write_text(self.original)
        package = base / "package"
        (package / "tools").mkdir(parents=True)
        (package / "patches").mkdir()
        self.patch = package / "patches/godotrealitykit-hand-tracking.patch"
        self.patch.write_text(patch)
        self.installer = package / "tools/apply_hand_tracking_patch.py"
        # Exercise the production installer unchanged apart from its expected baseline
        # commit. The fixture has its own commit and tiny patch, avoiding network access.
        source, count = re.subn(r'^BASE = "[0-9a-f]{40}"$', f'BASE = "{head}"', INSTALLER.read_text(), count=1, flags=re.MULTILINE)
        self.assertEqual(count, 1)
        self.installer.write_text(source)

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.checkout), *arguments], text=True, capture_output=True, check=True)

    def run_installer(self, *arguments, checkout=None):
        return subprocess.run([sys.executable, str(self.installer), str(checkout or self.checkout), *arguments], text=True, capture_output=True)

    def test_check_does_not_edit(self):
        self.assertEqual(self.run_installer("--check").returncode, 0)
        self.assertEqual(self.target.read_text(), self.original)
        self.assertEqual(self.git("diff", "--name-only").stdout, "")

    def test_apply_and_reapply_are_exact(self):
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.target.read_text(), self.changed)
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.run_installer("--check").returncode, 0)
        self.assertEqual(self.target.read_text(), self.changed)

    def test_unrelated_file_is_preserved(self):
        unrelated = self.checkout / "local-build.txt"
        unrelated.write_text("keep local configuration\n")
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(unrelated.read_text(), "keep local configuration\n")

    def test_unstaged_edit_is_rejected(self):
        self.target.write_text("user edit\n")
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.target.read_text(), "user edit\n")

    def test_staged_edit_is_rejected(self):
        self.target.write_text("staged user edit\n")
        self.git("add", TARGET)
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.git("show", ":" + TARGET).stdout, "staged user edit\n")

    def test_staged_edit_with_restored_worktree_is_rejected(self):
        self.target.write_text("staged user edit\n")
        self.git("add", TARGET)
        self.target.write_text(self.original)
        self.assertEqual(self.git("diff", "HEAD", "--", TARGET).stdout, "")
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.target.read_text(), self.original)
        self.assertEqual(self.git("show", ":" + TARGET).stdout, "staged user edit\n")

    def test_exact_staged_patch_is_a_noop(self):
        self.assertEqual(self.run_installer().returncode, 0)
        self.git("add", TARGET)
        before = self.git("diff", "--cached", "--binary").stdout
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--binary").stdout, before)

    def test_additional_edit_after_patch_is_rejected(self):
        self.assertEqual(self.run_installer().returncode, 0)
        self.target.write_text(self.changed + "local edit\n")
        self.assertNotEqual(self.run_installer("--check").returncode, 0)
        self.assertEqual(self.target.read_text(), self.changed + "local edit\n")

    def test_wrong_revision_is_rejected(self):
        self.git("commit", "--allow-empty", "-qm", "Different revision")
        self.assertNotEqual(self.run_installer("--check").returncode, 0)
        self.assertEqual(self.target.read_text(), self.original)

    def test_subdirectory_is_rejected(self):
        self.assertNotEqual(self.run_installer("--check", checkout=self.checkout / "godotrealitykit").returncode, 0)

    def test_missing_patch_is_rejected(self):
        self.patch.unlink()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.target.read_text(), self.original)

    def test_damaged_patch_is_rejected_without_editing(self):
        self.patch.write_text("not a patch\n")
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.target.read_text(), self.original)


if __name__ == "__main__":
    unittest.main()
