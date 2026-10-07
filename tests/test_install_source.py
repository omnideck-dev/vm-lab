#!/usr/bin/env python3
"""Exercise installer provenance from Git and archived controller sources."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
ARCHIVE_COMMIT = "a" * 40


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(root), "-c", "core.hooksPath=/dev/null", *arguments],
        text=True, stderr=subprocess.PIPE,
    ).strip()


class InstallerSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="controller provenance ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # A surrounding repository deliberately has a different commit. The
        # archived controller must never claim this unrelated repository's HEAD.
        git(self.root, "init", "--quiet")
        (self.root / "unrelated.txt").write_text("another project")
        git(self.root, "add", "unrelated.txt")
        git(self.root, "-c", "user.name=Lab tests", "-c", "user.email=lab@example.invalid",
            "commit", "--quiet", "-m", "Unrelated test project")
        self.outer_commit = git(self.root, "rev-parse", "HEAD")
        self.snapshot = self.root / "snapshot"
        shutil.copytree(SOURCE, self.snapshot, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        self.target = self.root / "installed"
        for name in ("golden", "disks", "base-images"):
            (self.target / name).mkdir(parents=True)

    def install_record(self):
        subprocess.run(
            ["bash", str(self.snapshot / "install.sh"), str(self.target)],
            check=True, capture_output=True, text=True,
        )
        return json.loads((self.target / "controller-install.json").read_text())

    def test_archive_uses_base_marker_but_always_reports_dirty(self):
        (self.snapshot / "SOURCE_COMMIT").write_text(ARCHIVE_COMMIT + "\n")
        record = self.install_record()
        self.assertEqual(record["sourceCommit"], ARCHIVE_COMMIT)
        self.assertNotEqual(record["sourceCommit"], self.outer_commit)
        self.assertTrue(record["sourceDirty"])
        self.assertIn("automation/baselines/linux-app-state.py", record["installedFilesSha256"])

    def test_missing_or_malformed_marker_cannot_borrow_outer_repository(self):
        marker = self.snapshot / "SOURCE_COMMIT"
        for value in (None, "not-a-commit", "a" * 39, ARCHIVE_COMMIT + "\nextra"):
            with self.subTest(value=value):
                if value is None:
                    marker.unlink(missing_ok=True)
                else:
                    marker.write_text(value)
                record = self.install_record()
                self.assertEqual(record["sourceCommit"], "unknown")
                self.assertTrue(record["sourceDirty"])

    def test_invalid_own_git_metadata_cannot_borrow_outer_repository(self):
        metadata = self.snapshot / ".git"
        (self.snapshot / "SOURCE_COMMIT").write_text(ARCHIVE_COMMIT + "\n")
        for kind in ("empty-directory", "corrupt-directory", "corrupt-file"):
            with self.subTest(kind=kind):
                if metadata.is_dir():
                    shutil.rmtree(metadata)
                elif metadata.exists():
                    metadata.unlink()
                if kind == "corrupt-file":
                    metadata.write_text("gitdir: /nonexistent/lab-test-git-dir\n")
                else:
                    metadata.mkdir()
                    if kind == "corrupt-directory":
                        (metadata / "HEAD").write_text("not a git reference\n")
                record = self.install_record()
                self.assertEqual(record["sourceCommit"], "unknown")
                self.assertNotEqual(record["sourceCommit"], self.outer_commit)
                self.assertTrue(record["sourceDirty"])

    def test_own_git_metadata_takes_priority_over_archive_marker(self):
        (self.snapshot / "SOURCE_COMMIT").write_text(ARCHIVE_COMMIT + "\n")
        git(self.snapshot, "init", "--quiet")
        git(self.snapshot, "add", ".")
        git(self.snapshot, "-c", "user.name=Lab tests", "-c", "user.email=lab@example.invalid",
            "commit", "--quiet", "-m", "Controller fixture")
        expected = git(self.snapshot, "rev-parse", "HEAD")
        record = self.install_record()
        self.assertEqual(record["sourceCommit"], expected)
        self.assertFalse(record["sourceDirty"])
        with (self.snapshot / "README.md").open("a") as handle:
            handle.write("\nfixture modification\n")
        record = self.install_record()
        self.assertEqual(record["sourceCommit"], expected)
        self.assertTrue(record["sourceDirty"])


if __name__ == "__main__":
    unittest.main()
