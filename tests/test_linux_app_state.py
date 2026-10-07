#!/usr/bin/env python3
"""Regression coverage for disposable baseline configuration cleanup."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "automation/baselines/linux-app-state.py"
SPEC = importlib.util.spec_from_file_location("linux_app_state", SCRIPT)
STATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATE)


class AppStateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lab home ")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.config = self.home / ".config"
        self.config.mkdir()

    def test_absent_state_is_clean_without_creating_directories(self):
        self.config.rmdir()
        STATE.check(self.home)
        STATE.clean(self.home)
        self.assertFalse(self.config.exists())

    def test_stale_desktop_and_cli_state_refuse_certification(self):
        for name in STATE.APP_CONFIG_NAMES:
            with self.subTest(name=name):
                leaf = self.config / name
                leaf.mkdir()
                (leaf / "saved.json").write_text("fixture")
                with self.assertRaisesRegex(ValueError, "Saved omnideck state remains"):
                    STATE.check(self.home)
                STATE.clean(self.home)
                self.assertFalse(leaf.exists())

    def test_cleanup_preserves_other_application_and_browser_configuration(self):
        browser = self.config / "mimeapps.list"
        browser.write_text("Firefox default")
        unrelated = self.config / "omnideck-other"
        unrelated.mkdir()
        (unrelated / "keep").write_text("untouched")
        for name in STATE.APP_CONFIG_NAMES:
            (self.config / name).mkdir()
        STATE.clean(self.home)
        STATE.clean(self.home)
        self.assertEqual(browser.read_text(), "Firefox default")
        self.assertEqual((unrelated / "keep").read_text(), "untouched")
        STATE.check(self.home)

    def test_dangling_and_external_leaf_links_are_detected_and_not_followed(self):
        outside = self.home / "outside"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("untouched")
        (self.config / "omnideck").symlink_to(outside, target_is_directory=True)
        (self.config / "omnideck-cli").symlink_to(self.home / "missing")
        with self.assertRaises(ValueError):
            STATE.check(self.home)
        STATE.clean(self.home)
        self.assertEqual(sentinel.read_text(), "untouched")
        STATE.check(self.home)

    def test_symlinked_config_parent_refuses_cleanup(self):
        self.config.rmdir()
        outside = self.home / "outside"
        outside.mkdir()
        sentinel = outside / "omnideck"
        sentinel.write_text("untouched")
        self.config.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "unexpected configuration parent"):
            STATE.clean(self.home)
        self.assertEqual(sentinel.read_text(), "untouched")

    def test_inspection_error_fails_closed(self):
        with mock.patch.object(STATE.os, "scandir", side_effect=PermissionError("denied")):
            with self.assertRaises(PermissionError):
                STATE.check(self.home)

    def test_invalid_homes_are_rejected(self):
        for home in ("/", "relative", self.home / "missing"):
            with self.subTest(home=home), self.assertRaises((ValueError, FileNotFoundError)):
                STATE.clean(home)

    def test_cli_check_is_read_only_and_exits_nonzero_for_stale_state(self):
        leaf = self.config / "omnideck-cli"
        leaf.mkdir()
        result = subprocess.run(
            ["python3", str(SCRIPT), "check", "--home", str(self.home)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Saved omnideck state remains", result.stderr)
        self.assertTrue(leaf.is_dir())


if __name__ == "__main__":
    unittest.main()
