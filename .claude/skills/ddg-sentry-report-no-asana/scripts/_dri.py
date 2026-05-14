"""Shared helpers for resolving the platform's Weekly Release DRI task and its
weekday status subtasks. Used by both `asana_file_summary` (script #3, to file
the new summary subtask) and `asana_lookup` (script #1, to fetch recent DRI
status notes for cross-referencing).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from ._asana import AsanaClient


class AmbiguousResolution(RuntimeError):
    """Raised when DRI / status-subtask resolution cannot pick uniquely."""

    def __init__(self, message: str, candidates: list[dict[str, Any]]):
        super().__init__(message)
        self.candidates = candidates


def resolve_dri_task(
    client: AsanaClient,
    *,
    platform_project_gid: str,
    dri_task_name: str,
) -> dict[str, Any]:
    """Find the open `<platform> App Weekly Release DRI` task. Raises on ambiguity.

    Disambiguation: prefer assigned over unassigned; if multiple assigned (or all
    unassigned), pick the most recent `created_at`.
    """
    results = client.search_tasks(
        projects_any=platform_project_gid,
        text=dri_task_name,
        completed=False,
        opt_fields="name,assignee,assignee.name,created_at,permalink_url",
        limit=20,
    )
    # Asana's text filter is fuzzy — keep only exact-name matches.
    exact = [t for t in results if t.get("name") == dri_task_name]
    if not exact:
        raise AmbiguousResolution(
            f"No open task named exactly {dri_task_name!r} in project {platform_project_gid}",
            results,
        )

    if len(exact) == 1:
        return exact[0]

    assigned = [t for t in exact if t.get("assignee") is not None]
    if len(assigned) == 1:
        return assigned[0]

    pool = assigned if assigned else exact
    pool_sorted = sorted(pool, key=lambda t: t.get("created_at") or "")
    if not pool_sorted:
        raise AmbiguousResolution("Empty DRI task pool after filtering", exact)
    return pool_sorted[-1]


def today_weekday_keyword(fallback: str | None) -> str:
    """Compute today's `<Weekday> status` keyword (e.g. 'Thursday status').

    Prefer an explicit fallback supplied in the input JSON — the skill's
    `analyze` mode used the system clock at run time, which is the authoritative
    source. Otherwise compute from `datetime.now()`.
    """
    if fallback:
        return fallback
    weekday = datetime.now().strftime("%A")
    return f"{weekday} status"


def pick_status_subtask(
    dri_task: dict[str, Any],
    weekday_keyword: str,
) -> dict[str, Any]:
    """Return the subtask whose name contains `weekday_keyword` (case-insensitive).

    Preference: incomplete over complete; ties broken by most-recent `created_at`.
    Raises AmbiguousResolution when no match.
    """
    subtasks = dri_task.get("subtasks", []) or []
    keyword_lc = weekday_keyword.lower()
    matches = [
        st for st in subtasks if keyword_lc in (st.get("name") or "").lower()
    ]
    if not matches:
        raise AmbiguousResolution(
            f"No subtask containing {weekday_keyword!r} (case-insensitive) "
            f"under DRI task {dri_task.get('gid')}",
            subtasks,
        )

    incomplete = [st for st in matches if not st.get("completed")]
    pool = incomplete or matches
    pool_sorted = sorted(pool, key=lambda st: st.get("created_at") or "")
    return pool_sorted[-1]


def pick_recent_status_subtasks(
    dri_task: dict[str, Any],
    *,
    limit: int = 4,
) -> list[dict[str, Any]]:
    """Return up to `limit` of the most recent `<Weekday> status` subtasks.

    Picks subtasks whose name ends in 'status' or 'status (...)' regardless of
    weekday — covers Monday through Friday entries. Sorted newest-first.
    """
    subtasks = dri_task.get("subtasks", []) or []
    weekdays = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
    matches: list[dict[str, Any]] = []
    for st in subtasks:
        name = (st.get("name") or "").lower()
        if " status" not in name:
            continue
        if not any(wd in name for wd in weekdays):
            continue
        matches.append(st)

    matches.sort(key=lambda st: st.get("created_at") or "", reverse=True)
    return matches[:limit]
