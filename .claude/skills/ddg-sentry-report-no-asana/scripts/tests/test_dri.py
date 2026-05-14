"""Unit tests for the shared DRI helpers in _dri."""

from __future__ import annotations

import unittest
from typing import Any
from unittest.mock import MagicMock

from .. import _dri


def _t(**fields: Any) -> dict[str, Any]:
    """Build a minimal task dict, defaulting common fields."""
    return {
        "gid": fields.get("gid", "1"),
        "name": fields.get("name", "Some task"),
        "assignee": fields.get("assignee"),
        "created_at": fields.get("created_at", "2026-05-14T00:00:00Z"),
        "permalink_url": fields.get("permalink_url", "https://app.asana.com/0/0/1"),
        **{k: v for k, v in fields.items() if k not in {"gid", "name", "assignee", "created_at", "permalink_url"}},
    }


class ResolveDriTaskTests(unittest.TestCase):
    def _client(self, results: list[dict[str, Any]]) -> Any:
        client = MagicMock()
        client.search_tasks.return_value = results
        return client

    def test_exact_match_single(self) -> None:
        client = self._client([_t(name="macOS App Weekly Release DRI")])
        out = _dri.resolve_dri_task(
            client, platform_project_gid="X", dri_task_name="macOS App Weekly Release DRI"
        )
        self.assertEqual(out["name"], "macOS App Weekly Release DRI")

    def test_filters_fuzzy_non_matches(self) -> None:
        client = self._client(
            [
                _t(gid="1", name="macOS App Weekly Release DRI"),
                _t(gid="2", name="🧰 Create a new release DRI task"),
            ]
        )
        out = _dri.resolve_dri_task(
            client, platform_project_gid="X", dri_task_name="macOS App Weekly Release DRI"
        )
        self.assertEqual(out["gid"], "1")

    def test_prefers_assigned(self) -> None:
        client = self._client(
            [
                _t(gid="1", name="macOS App Weekly Release DRI", assignee=None),
                _t(gid="2", name="macOS App Weekly Release DRI", assignee={"gid": "u1"}),
            ]
        )
        out = _dri.resolve_dri_task(
            client, platform_project_gid="X", dri_task_name="macOS App Weekly Release DRI"
        )
        self.assertEqual(out["gid"], "2")

    def test_both_assigned_picks_newest(self) -> None:
        client = self._client(
            [
                _t(gid="1", name="macOS App Weekly Release DRI", assignee={"gid": "u1"}, created_at="2026-05-01T00:00:00Z"),
                _t(gid="2", name="macOS App Weekly Release DRI", assignee={"gid": "u2"}, created_at="2026-05-14T00:00:00Z"),
            ]
        )
        out = _dri.resolve_dri_task(
            client, platform_project_gid="X", dri_task_name="macOS App Weekly Release DRI"
        )
        self.assertEqual(out["gid"], "2")

    def test_no_exact_match_raises(self) -> None:
        client = self._client([_t(gid="x", name="🧰 Create a new release DRI task")])
        with self.assertRaises(_dri.AmbiguousResolution):
            _dri.resolve_dri_task(
                client, platform_project_gid="X", dri_task_name="macOS App Weekly Release DRI"
            )


class TodayWeekdayKeywordTests(unittest.TestCase):
    def test_fallback_preferred(self) -> None:
        self.assertEqual(_dri.today_weekday_keyword("Wednesday status"), "Wednesday status")

    def test_computes_when_no_fallback(self) -> None:
        # Just assert the format; the actual weekday is system-dependent.
        result = _dri.today_weekday_keyword(None)
        self.assertTrue(result.endswith(" status"))


class PickStatusSubtaskTests(unittest.TestCase):
    def _dri_task(self, subtasks: list[dict[str, Any]]) -> dict[str, Any]:
        return {"gid": "dri", "subtasks": subtasks}

    def test_picks_match(self) -> None:
        dri = self._dri_task(
            [
                {"gid": "1", "name": "Monday status", "completed": False, "created_at": "2026-05-12T00:00:00Z"},
                {"gid": "2", "name": "Thursday status (May 14)", "completed": False, "created_at": "2026-05-14T00:00:00Z"},
            ]
        )
        out = _dri.pick_status_subtask(dri, "Thursday status")
        self.assertEqual(out["gid"], "2")

    def test_prefers_incomplete(self) -> None:
        dri = self._dri_task(
            [
                {"gid": "1", "name": "Thursday status (May 7)", "completed": True, "created_at": "2026-05-07T00:00:00Z"},
                {"gid": "2", "name": "Thursday status (May 14)", "completed": False, "created_at": "2026-05-14T00:00:00Z"},
            ]
        )
        out = _dri.pick_status_subtask(dri, "Thursday status")
        self.assertEqual(out["gid"], "2")

    def test_no_match_raises(self) -> None:
        dri = self._dri_task([{"gid": "1", "name": "Monday status", "completed": False, "created_at": "2026-05-12T00:00:00Z"}])
        with self.assertRaises(_dri.AmbiguousResolution):
            _dri.pick_status_subtask(dri, "Thursday status")


class PickRecentStatusSubtasksTests(unittest.TestCase):
    def test_returns_newest_first(self) -> None:
        dri = {
            "gid": "dri",
            "subtasks": [
                {"gid": "mon", "name": "Monday status (May 12)", "completed": True, "created_at": "2026-05-12T00:00:00Z"},
                {"gid": "wed", "name": "Wednesday status (May 14)", "completed": False, "created_at": "2026-05-14T00:00:00Z"},
                {"gid": "tue", "name": "Tuesday status (May 13)", "completed": True, "created_at": "2026-05-13T00:00:00Z"},
                {"gid": "noise", "name": "Some unrelated subtask", "completed": False, "created_at": "2026-05-14T01:00:00Z"},
            ],
        }
        out = _dri.pick_recent_status_subtasks(dri, limit=4)
        gids = [s["gid"] for s in out]
        self.assertEqual(gids, ["wed", "tue", "mon"])  # noise is filtered out

    def test_respects_limit(self) -> None:
        dri = {
            "gid": "dri",
            "subtasks": [
                {"gid": "a", "name": "Monday status", "created_at": "2026-05-01T00:00:00Z"},
                {"gid": "b", "name": "Tuesday status", "created_at": "2026-05-02T00:00:00Z"},
                {"gid": "c", "name": "Wednesday status", "created_at": "2026-05-03T00:00:00Z"},
                {"gid": "d", "name": "Thursday status", "created_at": "2026-05-04T00:00:00Z"},
                {"gid": "e", "name": "Friday status", "created_at": "2026-05-05T00:00:00Z"},
            ],
        }
        out = _dri.pick_recent_status_subtasks(dri, limit=3)
        self.assertEqual([s["gid"] for s in out], ["e", "d", "c"])

    def test_returns_empty_when_no_subtasks(self) -> None:
        self.assertEqual(_dri.pick_recent_status_subtasks({"gid": "dri"}), [])
        self.assertEqual(_dri.pick_recent_status_subtasks({"gid": "dri", "subtasks": []}), [])


if __name__ == "__main__":
    unittest.main()
