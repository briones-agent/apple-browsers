#!/usr/bin/env python3
"""Script #1 — Asana lookup.

Reads `analyze.json`, queries Asana for each cluster's existing tracking task
in the `Sentry Crash Reports` project, and writes `analyze.augmented.json`
with the `existing_asana_task` field populated per cluster.

Run from CLI:

    python3 -m scripts.asana_lookup --input analyze.json --output analyze.augmented.json

Or programmatically:

    from scripts.asana_lookup import run
    run(input_path="...", output_path="...")
"""

from __future__ import annotations

import logging
import re
import sys
from pathlib import Path
from typing import Any

from . import _common
from ._asana import AsanaClient, AsanaError
from ._dri import (
    AmbiguousResolution,
    pick_recent_status_subtasks,
    resolve_dri_task,
)

logger = logging.getLogger(__name__)

# Fallback section for pre-platform-split tasks.
FALLBACK_SECTION_GID = "1214294661819891"

# opt_fields required on every task search / get for the data-protection hook
# and the gating logic.
_TASK_OPT_FIELDS = (
    "name,permalink_url,custom_fields,memberships.section.gid,"
    "tags,tags.name,completed"
)
_GET_OPT_FIELDS = "tags,tags.name,completed,permalink_url,custom_fields,name"

# How many of the most recent <Weekday> status subtasks to pull (today + 3 prior).
_DRI_STATUS_LIMIT = 4

# Strip HTML tags for plaintext excerpts of DRI notes.
_HTML_TAG_RE = re.compile(r"<[^>]+>")
_WHITESPACE_RE = re.compile(r"\s+")
_TEXT_EXCERPT_LEN = 240


def _lookup_one_short_id(
    client: AsanaClient,
    short_id: str,
    *,
    sentry_crash_reports_project_gid: str,
    platform_section_gid: str,
    custom_field_gid: str,
) -> dict[str, Any] | None:
    """Search the platform section first, then the fallback section.

    Returns the first task dict whose comma-split custom-field contains
    `short_id` as an exact element, or None.
    """
    for sections_gid in (platform_section_gid, FALLBACK_SECTION_GID):
        results = client.search_tasks(
            projects_any=sentry_crash_reports_project_gid,
            sections_any=sections_gid,
            custom_field_value=(custom_field_gid, short_id),
            opt_fields=_TASK_OPT_FIELDS,
            limit=20,
        )
        for task in results:
            if _short_id_is_exact_match(task, short_id, custom_field_gid):
                logger.debug(
                    "short_id=%s matched task gid=%s in section=%s",
                    short_id,
                    task.get("gid"),
                    sections_gid,
                )
                return task
    return None


def _short_id_is_exact_match(task: dict[str, Any], short_id: str, custom_field_gid: str) -> bool:
    """Asana custom-field search is substring-match — require exact element after split on ','."""
    for cf in task.get("custom_fields", []) or []:
        if cf.get("gid") != custom_field_gid:
            continue
        raw = cf.get("display_value") or cf.get("text_value") or ""
        elements = _common.split_custom_field_value(raw)
        return short_id in elements
    return False


def _read_custom_field_value(task: dict[str, Any], custom_field_gid: str) -> str:
    for cf in task.get("custom_fields", []) or []:
        if cf.get("gid") == custom_field_gid:
            return cf.get("display_value") or cf.get("text_value") or ""
    return ""


def _resolve_duplicate_parent(
    client: AsanaClient,
    task: dict[str, Any],
) -> tuple[dict[str, Any], str | None]:
    """If task's name starts with [Duplicate], fetch the linked parent task.

    Asana uses the body to reference the parent in user-managed duplicates;
    a more reliable indicator is the name prefix. When recursing, we fetch
    the FIRST task whose name does NOT start with [Duplicate] by walking the
    `dependencies` field… in practice the parent is not machine-discoverable
    without a convention. The cleanest signal we have is the name prefix:
    if it's still [Duplicate], we surface the immediate match and let the
    operator inspect.

    Returns (resolved_task, original_gid_if_duplicate_or_None).
    """
    name = task.get("name", "")
    if not name.startswith("[Duplicate]"):
        return task, None
    # No reliable parent-resolution via API without convention; report the
    # immediate match plus the [Duplicate] flag so the operator can decide.
    return task, task.get("gid")


def _build_existing_asana_task(
    client: AsanaClient,
    task: dict[str, Any],
    cluster: dict[str, Any],
    *,
    platform: str,
    version_display: str,
    custom_field_gid: str,
) -> dict[str, Any]:
    resolved, duplicate_gid = _resolve_duplicate_parent(client, task)
    gid = resolved["gid"]
    permalink_url = resolved.get("permalink_url") or f"https://app.asana.com/0/0/{gid}"
    status = "completed" if resolved.get("completed") else "open"

    highest = _common.highest_fix_version(resolved.get("tags", []) or [], platform)
    fix_version_tag = highest[0] if highest else None
    fix_version_tuple = highest[1] if highest else None
    fix_version_compare = _common.compare_fix_version(fix_version_tuple, version_display)

    raw_cf = _read_custom_field_value(resolved, custom_field_gid)
    merged_short_ids = _common.split_custom_field_value(raw_cf)
    cluster_short_ids = cluster.get("short_ids", []) or []
    needs_extension = [s for s in cluster_short_ids if s not in merged_short_ids]

    return {
        "gid": gid,
        "url": permalink_url,
        "status": status,
        "fix_version_tag": fix_version_tag,
        "fix_version_compare": fix_version_compare,
        "is_duplicate_link": duplicate_gid,
        "merged_short_ids": merged_short_ids,
        "needs_short_id_extension": needs_extension,
    }


def _augment_cluster(
    client: AsanaClient,
    cluster: dict[str, Any],
    *,
    platform: str,
    version_display: str,
    sentry_crash_reports_project_gid: str,
    platform_section_gid: str,
    custom_field_gid: str,
    dry_run: bool,
) -> None:
    """Mutate `cluster` in place: set `existing_asana_task` to a dict or None."""
    short_ids = cluster.get("short_ids", []) or []
    if not short_ids:
        cluster["existing_asana_task"] = None
        return

    if dry_run:
        logger.info(
            "[dry-run] would search Asana for cluster=%s short_ids=%s",
            cluster.get("cluster_id"),
            short_ids,
        )
        cluster["existing_asana_task"] = None
        return

    matched: dict[str, Any] | None = None
    for short_id in short_ids:
        matched = _lookup_one_short_id(
            client,
            short_id,
            sentry_crash_reports_project_gid=sentry_crash_reports_project_gid,
            platform_section_gid=platform_section_gid,
            custom_field_gid=custom_field_gid,
        )
        if matched is not None:
            break

    if matched is None:
        cluster["existing_asana_task"] = None
        logger.info(
            "cluster=%s: no existing Asana task",
            cluster.get("cluster_id"),
        )
        return

    existing = _build_existing_asana_task(
        client,
        matched,
        cluster,
        platform=platform,
        version_display=version_display,
        custom_field_gid=custom_field_gid,
    )
    cluster["existing_asana_task"] = existing
    logger.info(
        "cluster=%s: matched gid=%s status=%s fix_version_compare=%s",
        cluster.get("cluster_id"),
        existing["gid"],
        existing["status"],
        existing["fix_version_compare"],
    )


def _html_to_excerpt(html: str | None) -> str:
    """Strip HTML tags and collapse whitespace; truncate to _TEXT_EXCERPT_LEN chars."""
    if not html:
        return ""
    text = _HTML_TAG_RE.sub(" ", html)
    text = _WHITESPACE_RE.sub(" ", text).strip()
    if len(text) > _TEXT_EXCERPT_LEN:
        text = text[: _TEXT_EXCERPT_LEN - 1] + "…"
    return text


def _existing_task_gid(cluster: dict[str, Any]) -> str | None:
    et = cluster.get("existing_asana_task")
    if isinstance(et, dict):
        return et.get("gid")
    return None


def _build_related_asana_tasks(
    client: AsanaClient,
    *,
    culprit: str,
    platform: str,
    version_display: str,
    sentry_crash_reports_project_gid: str,
    platform_section_gid: str,
    exclude_gids: set[str],
) -> list[dict[str, Any]]:
    """Search Sentry Crash Reports for tasks whose name contains `culprit`.

    Returns up to 5 entries with `gid`, `url`, `name`, `status`,
    `fix_version_tag`, `fix_version_compare`. Excludes any GID in
    `exclude_gids` (typically the cluster's existing_asana_task).
    Empty list when culprit is too generic to be useful (single-token symbols
    like `main`, `value`, `NSBundle.module`) — we skip the search in those
    cases to avoid false positives.
    """
    if not culprit or culprit in {"main", "value", "NSBundle.module"}:
        return []
    # Skip very short culprits — likely to over-match.
    if len(culprit) < 6:
        return []

    related: list[dict[str, Any]] = []
    seen: set[str] = set(exclude_gids)
    for sections_gid in (platform_section_gid, FALLBACK_SECTION_GID):
        results = client.search_tasks(
            projects_any=sentry_crash_reports_project_gid,
            sections_any=sections_gid,
            text=culprit,
            opt_fields="name,permalink_url,tags,tags.name,completed",
            limit=20,
        )
        for task in results:
            gid = task.get("gid")
            if not gid or gid in seen:
                continue
            name = task.get("name", "")
            # The search is fuzzy — keep only tasks whose name actually
            # contains the culprit (case-sensitive substring).
            if culprit not in name:
                continue
            seen.add(gid)
            highest = _common.highest_fix_version(task.get("tags", []) or [], platform)
            fix_version_tag = highest[0] if highest else None
            fix_version_tuple = highest[1] if highest else None
            related.append(
                {
                    "gid": gid,
                    "url": task.get("permalink_url") or f"https://app.asana.com/0/0/{gid}",
                    "name": name,
                    "status": "completed" if task.get("completed") else "open",
                    "fix_version_tag": fix_version_tag,
                    "fix_version_compare": _common.compare_fix_version(
                        fix_version_tuple, version_display
                    ),
                }
            )
    # Cap to 5; prioritise closed-with-future-fix-version first, then open, then others.
    def sort_key(t: dict[str, Any]) -> tuple[int, str]:
        if t["status"] == "completed" and t["fix_version_compare"] == "gt":
            rank = 0
        elif t["status"] == "open":
            rank = 1
        else:
            rank = 2
        return (rank, t.get("name", ""))
    related.sort(key=sort_key)
    return related[:5]


def _fetch_recent_dri_status_notes(
    client: AsanaClient,
    *,
    platform_project_gid: str,
    dri_task_name: str,
) -> list[dict[str, Any]]:
    """Fetch the platform's DRI task and its recent weekday status subtasks.

    Returns up to _DRI_STATUS_LIMIT entries with `gid`, `name`,
    `permalink_url`, `completed`, `created_at`, `text_excerpt`. Returns []
    when the DRI cannot be resolved (logged as warning; cross-references are
    best-effort).
    """
    try:
        dri_task = resolve_dri_task(
            client,
            platform_project_gid=platform_project_gid,
            dri_task_name=dri_task_name,
        )
    except AmbiguousResolution as e:
        logger.warning("DRI resolution skipped: %s", e)
        return []

    dri_with_subtasks = client.get_task(
        dri_task["gid"],
        opt_fields=(
            "subtasks,subtasks.name,subtasks.completed,subtasks.created_at,"
            "subtasks.permalink_url,tags,tags.name"
        ),
    )
    recent = pick_recent_status_subtasks(dri_with_subtasks, limit=_DRI_STATUS_LIMIT)
    if not recent:
        logger.info("DRI task has no recent <Weekday> status subtasks")
        return []

    notes: list[dict[str, Any]] = []
    for st in recent:
        gid = st.get("gid")
        if not gid:
            continue
        try:
            detail = client.get_task(gid, opt_fields="html_notes,tags,tags.name")
        except AsanaError as e:
            logger.warning("Skipping status subtask %s: %s", gid, e)
            continue
        notes.append(
            {
                "gid": gid,
                "name": st.get("name"),
                "permalink_url": st.get("permalink_url") or f"https://app.asana.com/0/0/{gid}",
                "completed": bool(st.get("completed")),
                "created_at": st.get("created_at"),
                "text_excerpt": _html_to_excerpt(detail.get("html_notes")),
            }
        )
    return notes


def run(input_path: str, output_path: str | None = None, *, dry_run: bool = False) -> str:
    """Read analyze.json from `input_path`, write augmented JSON to `output_path`.

    If `output_path` is None, derives it from `input_path` by replacing the
    `.json` suffix with `.augmented.json` (or appending if no suffix).

    Returns the absolute output path.
    """
    src = Path(input_path).resolve()
    if output_path is None:
        dst = src.with_name(src.stem + ".augmented.json")
    else:
        dst = Path(output_path).resolve()

    data = _common.load_json(src)
    _common.validate_schema(data, "analyze")

    platform = data["platform"]
    version_display = data["version_display"]
    project_gid = data["sentry_crash_reports_project_gid"]
    section_gid = data["platform_section_gid"]
    custom_field_gid = data["sentry_crash_group_custom_field_gid"]

    if data.get("crash_free"):
        logger.info("crash_free release: nothing to look up; passing analyze.json through")
        # Still emit the augmented file so downstream tools can run uniformly.
        data["generated_at"] = _common.now_iso_utc()
        _common.dump_json_atomic(dst, data)
        return str(dst)

    client = AsanaClient() if not dry_run else None  # type: ignore[assignment]

    clusters = data.get("clusters", []) or []
    logger.info("Augmenting %d clusters (dry_run=%s)", len(clusters), dry_run)
    for cluster in clusters:
        _augment_cluster(
            client,  # type: ignore[arg-type]
            cluster,
            platform=platform,
            version_display=version_display,
            sentry_crash_reports_project_gid=project_gid,
            platform_section_gid=section_gid,
            custom_field_gid=custom_field_gid,
            dry_run=dry_run,
        )
        # related_asana_tasks: culprit-name search; runs in addition to custom-field lookup.
        if dry_run:
            cluster["related_asana_tasks"] = []
        else:
            cluster["related_asana_tasks"] = _build_related_asana_tasks(
                client,  # type: ignore[arg-type]
                culprit=cluster.get("culprit", "") or "",
                platform=platform,
                version_display=version_display,
                sentry_crash_reports_project_gid=project_gid,
                platform_section_gid=section_gid,
                exclude_gids={
                    gid for gid in (_existing_task_gid(cluster),) if gid is not None
                },
            )
            if cluster["related_asana_tasks"]:
                logger.info(
                    "cluster=%s: %d related tasks (culprit=%s)",
                    cluster.get("cluster_id"),
                    len(cluster["related_asana_tasks"]),
                    cluster.get("culprit"),
                )

    # recent_dri_status_notes: once per run.
    lookup = data.get("weekly_release_dri_lookup") or {}
    if dry_run or not lookup.get("platform_project_gid") or not lookup.get("dri_task_name"):
        data["recent_dri_status_notes"] = []
    else:
        data["recent_dri_status_notes"] = _fetch_recent_dri_status_notes(
            client,  # type: ignore[arg-type]
            platform_project_gid=lookup["platform_project_gid"],
            dri_task_name=lookup["dri_task_name"],
        )
        logger.info(
            "recent_dri_status_notes: %d entries",
            len(data["recent_dri_status_notes"]),
        )

    data["generated_at"] = _common.now_iso_utc()
    _common.dump_json_atomic(dst, data)
    logger.info("Wrote %s", dst)
    return str(dst)


def _main(argv: list[str] | None = None) -> int:
    parser = _common.common_arg_parser("Script #1 — Asana existing-task lookup")
    parser.add_argument("--input", required=True, help="Path to analyze.json")
    parser.add_argument("--output", help="Path to write analyze.augmented.json")
    args = parser.parse_args(argv)
    _common.setup_logging(verbose=args.verbose)

    try:
        out = run(args.input, args.output, dry_run=args.dry_run)
    except (AsanaError, ValueError, FileNotFoundError) as e:
        logger.error("%s", e)
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
