#!/usr/bin/env python3
"""Script #0 — resolve the version to analyse from (platform, release-type).

The skill itself takes a `--version` argument; an orchestrator that drives
the skill from `(platform, release-type)` needs to look the version up first.
This script implements the resolution rules from section 1.3 of the parent
`ddg-sentry-report` skill, so the no-Asana variant can be driven the same
way without re-implementing the Asana searches inside the agent loop.

Resolution rules
----------------

* `public` — newest open `<platform> <version> is now public` task in
  Apple Deployments / Deployments (last 2 weeks), with the 12h cutoff
  (a brand-new release task may not have Sentry events yet).

* `internal` — newest open `<platform> App Release <version>` task in
  Apple Releases / `<platform>` section, `is_subtask=false`. On Monday
  UTC, drop the newest and take the next-newest (internal code freeze
  creates a fresh task at 01:00 UTC every Monday whose version has no
  Sentry events yet).

Run from CLI:

    python3 -m scripts.resolve_version --platform macos --release-type public

Or programmatically:

    from scripts.resolve_version import run
    version = run(platform="macos", release_type="public")  # → "1.186"
"""

from __future__ import annotations

import logging
import re
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

from . import _common
from ._asana import AsanaClient, AsanaError

logger = logging.getLogger(__name__)

APPLE_DEPLOYMENTS_PROJECT_GID = "1210977615028562"
APPLE_DEPLOYMENTS_LAST_2_WEEKS_SECTION_GID = "1210977615028567"
APPLE_RELEASES_PROJECT_GID = "1209802997613369"
APPLE_RELEASES_PLATFORM_SECTION_GIDS = {
    "ios": "1209802997613372",
    "macos": "1209802997613373",
}
PLATFORM_DISPLAY = {"ios": "iOS", "macos": "macOS"}
PUBLIC_FRESHNESS_CUTOFF = timedelta(hours=12)

_SEARCH_OPT_FIELDS = "name,gid,created_at,permalink_url"


class ResolutionError(RuntimeError):
    """Stop-and-ask outcome — caller should surface to the operator."""


def _public_name_pattern(platform_display: str) -> re.Pattern[str]:
    return re.compile(rf"^{re.escape(platform_display)} (\d+)\.(\d+)\.(\d+) is now public$")


def _internal_name_pattern(platform_display: str) -> re.Pattern[str]:
    return re.compile(rf"^{re.escape(platform_display)} App Release (\d+)\.(\d+)\.(\d+)$")


def _parse_created_at(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _collapse_to_major_minor(version: tuple[int, int, int]) -> str:
    return f"{version[0]}.{version[1]}"


def _filter_public_candidates(
    tasks: list[dict[str, Any]],
    *,
    platform_display: str,
    now_utc: datetime,
) -> list[tuple[dict[str, Any], tuple[int, int, int], datetime]]:
    """Apply 1.3 public-branch filters: exact-name match + 12h freshness cutoff.

    Returns surviving (task, version_tuple, created_at) tuples sorted newest first.
    """
    pattern = _public_name_pattern(platform_display)
    cutoff = now_utc - PUBLIC_FRESHNESS_CUTOFF
    candidates: list[tuple[dict[str, Any], tuple[int, int, int], datetime]] = []
    for task in tasks:
        match = pattern.match(task.get("name", ""))
        if match is None:
            continue
        created_at = _parse_created_at(task.get("created_at"))
        if created_at is None:
            continue
        if created_at > cutoff:
            logger.info(
                "drop fresh candidate (created %s < 12h ago): %s",
                created_at.isoformat(),
                task.get("name"),
            )
            continue
        version = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
        candidates.append((task, version, created_at))
    candidates.sort(key=lambda c: c[2], reverse=True)
    return candidates


def _filter_internal_candidates(
    tasks: list[dict[str, Any]],
    *,
    platform_display: str,
) -> list[tuple[dict[str, Any], tuple[int, int, int], datetime]]:
    """Apply 1.3 internal-branch filters: exact-name match + drop missing created_at.

    Returns surviving (task, version_tuple, created_at) tuples sorted newest first.
    The Monday-UTC drop-newest rule is applied by the caller against this list.
    """
    pattern = _internal_name_pattern(platform_display)
    candidates: list[tuple[dict[str, Any], tuple[int, int, int], datetime]] = []
    for task in tasks:
        match = pattern.match(task.get("name", ""))
        if match is None:
            continue
        created_at = _parse_created_at(task.get("created_at"))
        if created_at is None:
            continue
        version = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
        candidates.append((task, version, created_at))
    candidates.sort(key=lambda c: c[2], reverse=True)
    return candidates


def _pick_internal_candidate(
    candidates: list[tuple[dict[str, Any], tuple[int, int, int], datetime]],
    *,
    is_monday_utc: bool,
) -> tuple[dict[str, Any], tuple[int, int, int], datetime]:
    """Monday UTC: drop newest, take next; otherwise take newest."""
    if not candidates:
        raise ResolutionError(
            "no open `<platform> App Release X.Y.Z` task matches the filter"
        )
    if is_monday_utc:
        if len(candidates) < 2:
            raise ResolutionError(
                "Monday UTC: only one matching internal release task remains after "
                "filtering. The newest one is likely the just-cut code-freeze task "
                "with no Sentry events yet — refusing to fall back to it. "
                f"Sole candidate: {candidates[0][0].get('name')!r} "
                f"({candidates[0][0].get('permalink_url')})"
            )
        return candidates[1]
    return candidates[0]


def _resolve_public(
    client: AsanaClient,
    *,
    platform: str,
    now_utc: datetime,
) -> str:
    platform_display = PLATFORM_DISPLAY[platform]
    tasks = client.search_tasks(
        projects_any=APPLE_DEPLOYMENTS_PROJECT_GID,
        sections_any=APPLE_DEPLOYMENTS_LAST_2_WEEKS_SECTION_GID,
        text="is now public",
        completed=False,
        opt_fields=_SEARCH_OPT_FIELDS,
        limit=20,
    )
    candidates = _filter_public_candidates(
        tasks, platform_display=platform_display, now_utc=now_utc
    )
    if not candidates:
        raise ResolutionError(
            f"no open `{platform_display} X.Y.Z is now public` task in Apple "
            f"Deployments / Deployments (last 2 weeks) after the 12h cutoff "
            f"(searched {len(tasks)} tasks)"
        )
    task, version, created_at = candidates[0]
    collapsed = _collapse_to_major_minor(version)
    logger.info(
        "public branch: %r created=%s → version=%s",
        task.get("name"),
        created_at.isoformat(),
        collapsed,
    )
    return collapsed


def _resolve_internal(
    client: AsanaClient,
    *,
    platform: str,
    now_utc: datetime,
) -> str:
    platform_display = PLATFORM_DISPLAY[platform]
    section_gid = APPLE_RELEASES_PLATFORM_SECTION_GIDS[platform]
    tasks = client.search_tasks(
        projects_any=APPLE_RELEASES_PROJECT_GID,
        sections_any=section_gid,
        text=f"{platform_display} App Release",
        completed=False,
        is_subtask=False,
        opt_fields=_SEARCH_OPT_FIELDS,
        limit=10,
    )
    candidates = _filter_internal_candidates(tasks, platform_display=platform_display)
    is_monday_utc = now_utc.weekday() == 0
    task, version, created_at = _pick_internal_candidate(
        candidates, is_monday_utc=is_monday_utc
    )
    collapsed = _collapse_to_major_minor(version)
    logger.info(
        "internal branch (monday_utc=%s): %r created=%s → version=%s",
        is_monday_utc,
        task.get("name"),
        created_at.isoformat(),
        collapsed,
    )
    return collapsed


def run(
    *,
    platform: str,
    release_type: str,
    dry_run: bool = False,
    now_utc: datetime | None = None,
) -> str:
    """Resolve the version from Asana for `(platform, release_type)`.

    `now_utc` is injectable for tests; defaults to `datetime.now(timezone.utc)`.
    """
    plat = platform.lower().strip()
    rtype = release_type.lower().strip()
    if plat not in PLATFORM_DISPLAY:
        raise ValueError(f"platform must be 'ios' or 'macos', got {platform!r}")
    if rtype not in ("public", "internal"):
        raise ValueError(
            f"release_type must be 'public' or 'internal', got {release_type!r}"
        )

    when = now_utc or datetime.now(timezone.utc)

    if dry_run:
        logger.info("[dry-run] would resolve %s / %s using Asana lookups", plat, rtype)
        return ""

    client = AsanaClient()
    if rtype == "public":
        return _resolve_public(client, platform=plat, now_utc=when)
    return _resolve_internal(client, platform=plat, now_utc=when)


def _main(argv: list[str] | None = None) -> int:
    parser = _common.common_arg_parser(
        "Script #0 — resolve version from (platform, release-type) via Asana"
    )
    parser.add_argument("--platform", required=True, choices=("ios", "macos"))
    parser.add_argument(
        "--release-type", required=True, choices=("public", "internal"),
        dest="release_type",
    )
    args = parser.parse_args(argv)
    _common.setup_logging(verbose=args.verbose)

    try:
        version = run(
            platform=args.platform,
            release_type=args.release_type,
            dry_run=args.dry_run,
        )
    except ResolutionError as e:
        logger.error("%s", e)
        return 2
    except (AsanaError, ValueError) as e:
        logger.error("%s", e)
        return 1

    if version:
        print(version)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
