"""Unit tests for the related_asana_tasks + recent_dri_status_notes logic
added to asana_lookup for Fix A.
"""

from __future__ import annotations

import unittest
from typing import Any
from unittest.mock import MagicMock

from .. import asana_lookup


def _t(**fields: Any) -> dict[str, Any]:
    return {
        "gid": fields.get("gid", "1"),
        "name": fields.get("name", "Task"),
        "permalink_url": fields.get("permalink_url", "https://app.asana.com/0/0/1"),
        "tags": fields.get("tags", []),
        "completed": fields.get("completed", False),
    }


PROJECT = "1214294661819890"
SECTION = "1214291024165659"  # macOS


class HtmlToExcerptTests(unittest.TestCase):
    def test_strips_tags(self) -> None:
        out = asana_lookup._html_to_excerpt("<body><strong>Hi</strong> there</body>")
        self.assertEqual(out, "Hi there")

    def test_collapses_whitespace(self) -> None:
        out = asana_lookup._html_to_excerpt("<body>\n  Hi   <em>there</em>\n</body>")
        self.assertEqual(out, "Hi there")

    def test_truncates_long_text(self) -> None:
        long = "<body>" + "x" * 500 + "</body>"
        out = asana_lookup._html_to_excerpt(long)
        self.assertLessEqual(len(out), 240)
        self.assertTrue(out.endswith("…"))

    def test_empty_input(self) -> None:
        self.assertEqual(asana_lookup._html_to_excerpt(None), "")
        self.assertEqual(asana_lookup._html_to_excerpt(""), "")


class BuildRelatedAsanaTasksTests(unittest.TestCase):
    def _client_with(self, *return_lists: list[dict[str, Any]]) -> Any:
        """Each successive search_tasks call returns the next list."""
        client = MagicMock()
        client.search_tasks.side_effect = list(return_lists)
        return client

    def test_skips_generic_culprits(self) -> None:
        for culprit in ("main", "value", "NSBundle.module", "abc"):
            result = asana_lookup._build_related_asana_tasks(
                client=MagicMock(),
                culprit=culprit,
                platform="macos",
                version_display="1.186",
                sentry_crash_reports_project_gid=PROJECT,
                platform_section_gid=SECTION,
                exclude_gids=set(),
            )
            self.assertEqual(result, [], f"expected empty for culprit={culprit!r}")

    def test_finds_culprit_match(self) -> None:
        match = _t(
            gid="abc",
            name="SIGKILL sqlcipher_cc_kdf",
            completed=True,
            tags=[{"name": "macos-app-release-1.190.0"}],
            permalink_url="https://app.asana.com/0/0/abc",
        )
        client = self._client_with([match], [])  # platform section hit, fallback empty
        result = asana_lookup._build_related_asana_tasks(
            client=client,
            culprit="sqlcipher_cc_kdf",
            platform="macos",
            version_display="1.186",
            sentry_crash_reports_project_gid=PROJECT,
            platform_section_gid=SECTION,
            exclude_gids=set(),
        )
        self.assertEqual(len(result), 1)
        entry = result[0]
        self.assertEqual(entry["gid"], "abc")
        self.assertEqual(entry["status"], "completed")
        self.assertEqual(entry["fix_version_tag"], "macos-app-release-1.190.0")
        self.assertEqual(entry["fix_version_compare"], "gt")

    def test_excludes_existing_task_gid(self) -> None:
        match = _t(gid="dup", name="SIGKILL sqlcipher_cc_kdf")
        client = self._client_with([match], [match])
        result = asana_lookup._build_related_asana_tasks(
            client=client,
            culprit="sqlcipher_cc_kdf",
            platform="macos",
            version_display="1.186",
            sentry_crash_reports_project_gid=PROJECT,
            platform_section_gid=SECTION,
            exclude_gids={"dup"},
        )
        self.assertEqual(result, [])

    def test_filters_fuzzy_non_matches(self) -> None:
        # Asana's text filter is fuzzy — we require the culprit to be a literal
        # substring of the task's name. A task containing "sqlite" should NOT
        # match a culprit of "sqlcipher_cc_kdf".
        irrelevant = _t(gid="irr", name="SIGSEGV sqlite3Step")
        client = self._client_with([irrelevant], [])
        result = asana_lookup._build_related_asana_tasks(
            client=client,
            culprit="sqlcipher_cc_kdf",
            platform="macos",
            version_display="1.186",
            sentry_crash_reports_project_gid=PROJECT,
            platform_section_gid=SECTION,
            exclude_gids=set(),
        )
        self.assertEqual(result, [])

    def test_sort_prioritises_closed_with_future_fix(self) -> None:
        closed_old_fix = _t(
            gid="a",
            name="SIGKILL sqlcipher_cc_kdf X",
            completed=True,
            tags=[{"name": "macos-app-release-1.180.0"}],
        )
        open_task = _t(gid="b", name="SIGKILL sqlcipher_cc_kdf Y", completed=False)
        closed_future_fix = _t(
            gid="c",
            name="SIGKILL sqlcipher_cc_kdf Z",
            completed=True,
            tags=[{"name": "macos-app-release-1.190.0"}],
        )
        client = self._client_with([closed_old_fix, open_task, closed_future_fix], [])
        result = asana_lookup._build_related_asana_tasks(
            client=client,
            culprit="sqlcipher_cc_kdf",
            platform="macos",
            version_display="1.186",
            sentry_crash_reports_project_gid=PROJECT,
            platform_section_gid=SECTION,
            exclude_gids=set(),
        )
        self.assertEqual([r["gid"] for r in result], ["c", "b", "a"])

    def test_caps_at_5(self) -> None:
        many = [_t(gid=f"x{i}", name=f"SIGKILL sqlcipher_cc_kdf {i}") for i in range(10)]
        client = self._client_with(many, [])
        result = asana_lookup._build_related_asana_tasks(
            client=client,
            culprit="sqlcipher_cc_kdf",
            platform="macos",
            version_display="1.186",
            sentry_crash_reports_project_gid=PROJECT,
            platform_section_gid=SECTION,
            exclude_gids=set(),
        )
        self.assertEqual(len(result), 5)


if __name__ == "__main__":
    unittest.main()
