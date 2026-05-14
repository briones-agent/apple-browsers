"""Unit tests for resolve_version: filters, Monday-UTC drop-newest, collapse."""

from __future__ import annotations

import unittest
from datetime import datetime, timezone
from typing import Any

from .. import resolve_version


def _task(
    *,
    gid: str = "1",
    name: str = "",
    created_at: str | None = None,
    permalink_url: str = "",
) -> dict[str, Any]:
    return {
        "gid": gid,
        "name": name,
        "created_at": created_at,
        "permalink_url": permalink_url,
    }


# Wednesday at noon UTC.
WED_UTC = datetime(2026, 5, 13, 12, 0, 0, tzinfo=timezone.utc)
# Monday at noon UTC.
MON_UTC = datetime(2026, 5, 11, 12, 0, 0, tzinfo=timezone.utc)


class FilterPublicCandidatesTests(unittest.TestCase):
    def test_exact_name_match_keeps_platform(self) -> None:
        tasks = [
            _task(
                name="iOS 7.218.0 is now public",
                created_at="2026-05-11T08:00:00Z",
            ),
            _task(
                name="macOS 1.186.0 is now public",
                created_at="2026-05-12T08:00:00Z",
            ),
        ]
        result = resolve_version._filter_public_candidates(
            tasks, platform_display="macOS", now_utc=WED_UTC
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0]["name"], "macOS 1.186.0 is now public")
        self.assertEqual(result[0][1], (1, 186, 0))

    def test_twelve_hour_cutoff_drops_fresh(self) -> None:
        fresh = "2026-05-13T08:00:00Z"  # 4h before WED_UTC
        stale = "2026-05-12T08:00:00Z"  # 28h before WED_UTC
        tasks = [
            _task(name="macOS 1.187.0 is now public", created_at=fresh),
            _task(name="macOS 1.186.0 is now public", created_at=stale),
        ]
        result = resolve_version._filter_public_candidates(
            tasks, platform_display="macOS", now_utc=WED_UTC
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][1], (1, 186, 0))

    def test_sorts_newest_first_after_cutoff(self) -> None:
        tasks = [
            _task(
                name="macOS 1.184.0 is now public",
                created_at="2026-05-01T08:00:00Z",
            ),
            _task(
                name="macOS 1.186.0 is now public",
                created_at="2026-05-11T08:00:00Z",
            ),
            _task(
                name="macOS 1.185.0 is now public",
                created_at="2026-05-05T08:00:00Z",
            ),
        ]
        result = resolve_version._filter_public_candidates(
            tasks, platform_display="macOS", now_utc=WED_UTC
        )
        self.assertEqual([c[1] for c in result], [(1, 186, 0), (1, 185, 0), (1, 184, 0)])

    def test_substring_name_dropped(self) -> None:
        tasks = [
            _task(
                name="macOS 1.186.0 is now public (followup)",
                created_at="2026-05-11T08:00:00Z",
            ),
            _task(
                name="A bit macOS 1.186.0 is now public",
                created_at="2026-05-11T08:00:00Z",
            ),
        ]
        result = resolve_version._filter_public_candidates(
            tasks, platform_display="macOS", now_utc=WED_UTC
        )
        self.assertEqual(result, [])

    def test_missing_created_at_dropped(self) -> None:
        tasks = [
            _task(name="macOS 1.186.0 is now public", created_at=None),
        ]
        result = resolve_version._filter_public_candidates(
            tasks, platform_display="macOS", now_utc=WED_UTC
        )
        self.assertEqual(result, [])


class FilterInternalCandidatesTests(unittest.TestCase):
    def test_exact_name_pattern(self) -> None:
        tasks = [
            _task(name="macOS App Release 1.186.0", created_at="2026-05-10T08:00:00Z"),
            _task(name="macOS App Release 1.186.0 phased rollout", created_at="2026-05-10T08:00:00Z"),
            _task(name="iOS App Release 7.220.0", created_at="2026-05-10T08:00:00Z"),
        ]
        result = resolve_version._filter_internal_candidates(
            tasks, platform_display="macOS"
        )
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0][0]["name"], "macOS App Release 1.186.0")

    def test_sorts_newest_first(self) -> None:
        tasks = [
            _task(name="macOS App Release 1.184.0", created_at="2026-05-01T08:00:00Z"),
            _task(name="macOS App Release 1.186.0", created_at="2026-05-11T08:00:00Z"),
            _task(name="macOS App Release 1.185.0", created_at="2026-05-05T08:00:00Z"),
        ]
        result = resolve_version._filter_internal_candidates(
            tasks, platform_display="macOS"
        )
        self.assertEqual([c[1] for c in result], [(1, 186, 0), (1, 185, 0), (1, 184, 0)])


class PickInternalCandidateTests(unittest.TestCase):
    def _make(self, versions_with_dates: list[tuple[tuple[int, int, int], str]]):
        out = []
        for version, created_at in versions_with_dates:
            out.append(
                (
                    {"name": "macOS App Release " + ".".join(map(str, version))},
                    version,
                    datetime.fromisoformat(created_at.replace("Z", "+00:00")),
                )
            )
        return out

    def test_non_monday_takes_newest(self) -> None:
        candidates = self._make(
            [
                ((1, 186, 0), "2026-05-11T08:00:00Z"),
                ((1, 185, 0), "2026-05-05T08:00:00Z"),
            ]
        )
        task, version, _ = resolve_version._pick_internal_candidate(
            candidates, is_monday_utc=False
        )
        self.assertEqual(version, (1, 186, 0))

    def test_monday_drops_newest_takes_second(self) -> None:
        candidates = self._make(
            [
                ((1, 187, 0), "2026-05-11T01:00:00Z"),  # just-cut code-freeze task
                ((1, 186, 0), "2026-05-04T08:00:00Z"),  # what we want
            ]
        )
        task, version, _ = resolve_version._pick_internal_candidate(
            candidates, is_monday_utc=True
        )
        self.assertEqual(version, (1, 186, 0))

    def test_monday_with_only_one_match_raises(self) -> None:
        candidates = self._make([((1, 187, 0), "2026-05-11T01:00:00Z")])
        with self.assertRaises(resolve_version.ResolutionError):
            resolve_version._pick_internal_candidate(candidates, is_monday_utc=True)

    def test_empty_list_raises(self) -> None:
        with self.assertRaises(resolve_version.ResolutionError):
            resolve_version._pick_internal_candidate([], is_monday_utc=False)


class CollapseToMajorMinorTests(unittest.TestCase):
    def test_typical(self) -> None:
        self.assertEqual(resolve_version._collapse_to_major_minor((7, 218, 0)), "7.218")

    def test_patch_nonzero_still_collapses(self) -> None:
        self.assertEqual(resolve_version._collapse_to_major_minor((1, 186, 3)), "1.186")


class WeekdayDayUTCTests(unittest.TestCase):
    """Sanity-check that the Monday-UTC detection uses weekday() == 0."""

    def test_monday_is_zero(self) -> None:
        self.assertEqual(MON_UTC.weekday(), 0)

    def test_wednesday_is_two(self) -> None:
        self.assertEqual(WED_UTC.weekday(), 2)


class ParseCreatedAtTests(unittest.TestCase):
    def test_z_suffix(self) -> None:
        out = resolve_version._parse_created_at("2026-05-12T08:00:00Z")
        self.assertIsNotNone(out)
        assert out is not None
        self.assertEqual(out.year, 2026)
        self.assertEqual(out.tzinfo, timezone.utc)

    def test_explicit_offset(self) -> None:
        out = resolve_version._parse_created_at("2026-05-12T08:00:00+00:00")
        self.assertIsNotNone(out)

    def test_bad_input(self) -> None:
        self.assertIsNone(resolve_version._parse_created_at(None))
        self.assertIsNone(resolve_version._parse_created_at(""))
        self.assertIsNone(resolve_version._parse_created_at("garbage"))


if __name__ == "__main__":
    unittest.main()
