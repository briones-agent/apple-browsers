"""Unit tests for asana_file_summary — input parsing + status-subtask picker."""

from __future__ import annotations

import unittest

from .. import asana_file_summary


class ReadInputsTests(unittest.TestCase):
    def test_summary_json_happy(self) -> None:
        data = {
            "schema_version": 1,
            "platform": "macOS",
            "name": "Sentry summary - macOS 1.186 - 2026-05-14",
            "html_notes": "<body>...</body>",
            "is_crash_free_report": False,
            "weekly_release_dri_lookup": {
                "platform_project_gid": "1201037661562251",
                "dri_task_name": "macOS App Weekly Release DRI",
                "weekday_status_keyword": "Thursday status",
            },
        }
        result = asana_file_summary._read_inputs(data)
        self.assertEqual(result["name"], data["name"])
        self.assertEqual(result["html_notes"], data["html_notes"])
        self.assertFalse(result["is_crash_free"])

    def test_analyze_json_crash_free(self) -> None:
        data = {
            "schema_version": 1,
            "platform": "macos",
            "version": "1.187",
            "clusters": [],
            "crash_free": True,
            "summary_name": "Sentry summary - macOS 1.187 - 2026-05-14",
            "crash_free_html_notes": "<body>crash-free</body>",
            "weekly_release_dri_lookup": {
                "platform_project_gid": "1201037661562251",
                "dri_task_name": "macOS App Weekly Release DRI",
                "weekday_status_keyword": "Thursday status",
            },
        }
        result = asana_file_summary._read_inputs(data)
        self.assertEqual(result["name"], "Sentry summary - macOS 1.187 - 2026-05-14")
        self.assertEqual(result["html_notes"], "<body>crash-free</body>")
        self.assertTrue(result["is_crash_free"])

    def test_crash_free_missing_fields(self) -> None:
        data = {
            "schema_version": 1,
            "platform": "macos",
            "version": "1.187",
            "clusters": [],
            "crash_free": True,
            # missing summary_name + crash_free_html_notes
            "weekly_release_dri_lookup": {
                "platform_project_gid": "1",
                "dri_task_name": "x",
            },
        }
        with self.assertRaises(ValueError):
            asana_file_summary._read_inputs(data)

    def test_missing_dri_lookup(self) -> None:
        data = {
            "schema_version": 1,
            "platform": "macOS",
            "name": "x",
            "html_notes": "<body/>",
        }
        with self.assertRaises(ValueError):
            asana_file_summary._read_inputs(data)


# Status-subtask picker coverage lives in test_dri.PickStatusSubtaskTests
# (the function moved to _dri after refactoring). Keep this file focused on
# the _read_inputs normalisation logic that is unique to asana_file_summary.


if __name__ == "__main__":
    unittest.main()
