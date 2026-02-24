# MetricsAggregator API Specification

This document specifies the MetricsAggregator: a SQL-backed component that aggregates counter and gauge metrics per pixel, optionally buckets numeric values, and produces outbox entries ready for pixel dispatch. The spec is implementation-agnostic so the same behavior can be implemented on other platforms (e.g. Android, Kotlin, JavaScript).

---

## 1. Overview

- **Purpose**: Accumulate metrics (counters and gauges) keyed by pixel; after a configurable aggregation interval, turn mature metrics into a single outbox row per pixel with URL-encoded parameters for sending.
- **Concurrency**: The reference implementation uses a single writer; all mutations and collection run in a write transaction. Implementations must ensure collection and mutations are serialized with respect to each other.
- **Timestamps**: All datetimes are stored and returned in ISO 8601 format with fractional seconds, UTC: `YYYY-MM-DDTHH:MM:SS.ffffffZ`.

---

## 2. SQL Schema

The schema is described in SQLite-compatible DDL. Other SQL engines should map types and defaults appropriately (e.g. `REAL` → `DOUBLE`, `TEXT` → `VARCHAR`/string, `INTEGER` → 64-bit integer where applicable).

Enable foreign keys if your engine supports them (e.g. `PRAGMA foreign_keys = ON` for SQLite).

### 2.1 Table: `pixel_config`

Configures each pixel and its aggregation interval.

| Column                 | Type    | Constraints        | Description |
|------------------------|---------|--------------------|-------------|
| `pixel`                | TEXT    | PRIMARY KEY        | Pixel identifier. |
| `aggregation_interval` | REAL    | NOT NULL, DEFAULT 3600 | Seconds after which metrics for this pixel are considered mature for collection. |

**DDL (SQLite):**

```sql
CREATE TABLE pixel_config (
    pixel TEXT PRIMARY KEY,
    aggregation_interval REAL NOT NULL DEFAULT 3600
);
```

### 2.2 Table: `metric_buckets`

Optional bucketing rules per (pixel, metric_name). Ranges are evaluated in `ordinal` order; the first matching bucket supplies the output name. If no bucket matches and any bucket exists for that metric, the value is dropped at collection time.

| Column           | Type    | Constraints   | Description |
|------------------|---------|---------------|-------------|
| `id`             | INTEGER | PRIMARY KEY AUTOINCREMENT | Surrogate key. |
| `pixel`          | TEXT    | NOT NULL      | Must match a pixel. |
| `metric_name`    | TEXT    | NOT NULL      | Metric to bucket. |
| `ordinal`        | INTEGER | NOT NULL      | Order of evaluation (0, 1, 2, …). |
| `min_inclusive`  | REAL    | NOT NULL      | Lower bound (inclusive). |
| `max_exclusive`  | REAL    | NULL allowed  | Upper bound (exclusive). NULL means no upper bound. |
| `name`           | TEXT    | NOT NULL      | Label emitted when value falls in this range. |

**Unique constraint:** `(pixel, metric_name, ordinal)` must be unique.

**DDL (SQLite):**

```sql
CREATE TABLE metric_buckets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pixel TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    min_inclusive REAL NOT NULL,
    max_exclusive REAL,
    name TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_metric_buckets_unique ON metric_buckets(pixel, metric_name, ordinal);
```

### 2.3 Table: `aggregated_metrics`

Live metric values, one row per (pixel, metric_name). Counters are accumulated; gauges are replaced.

| Column        | Type    | Constraints   | Description |
|---------------|---------|---------------|-------------|
| `id`          | INTEGER | PRIMARY KEY AUTOINCREMENT | Surrogate key. |
| `pixel`       | TEXT    | NOT NULL      | Pixel identifier. |
| `metric_type`| TEXT    | NOT NULL      | Either `"counter"` or `"gauge"`. |
| `metric_name`| TEXT    | NOT NULL      | Metric name. |
| `value`       | REAL    | NOT NULL DEFAULT 0 | Current value. |
| `created_at`  | TEXT    | NOT NULL      | ISO 8601 UTC when the row was first inserted. |
| `updated_at`  | TEXT    | NOT NULL      | ISO 8601 UTC of last update. |

**Unique constraint:** `(pixel, metric_name)` must be unique.

**DDL (SQLite):**

```sql
CREATE TABLE aggregated_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pixel TEXT NOT NULL,
    metric_type TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    value REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX idx_aggregated_metrics_unique ON aggregated_metrics(pixel, metric_name);
```

### 2.4 Table: `metrics_outbox`

Outbox of collected pixels ready for dispatch. One row per collected pixel; all metrics for that pixel are encoded in `parameters`.

| Column          | Type    | Constraints   | Description |
|-----------------|---------|---------------|-------------|
| `id`            | INTEGER | PRIMARY KEY AUTOINCREMENT | Stable id for markSent/markFailed. |
| `pixel`         | TEXT    | NOT NULL      | Pixel name. |
| `interval_start` | TEXT  | NOT NULL      | ISO 8601 UTC; start of the collection interval (oldest `created_at` among collected metrics for this pixel). |
| `interval_end`  | TEXT   | NOT NULL      | ISO 8601 UTC; when collection ran. |
| `parameters`    | TEXT    | NOT NULL      | URL-encoded key-value pairs (see §4). |
| `attempts`      | INTEGER | NOT NULL DEFAULT 0 | Number of failed send attempts. |
| `last_attempt`  | TEXT    | NULL          | ISO 8601 UTC of last failed attempt. |

**DDL (SQLite):**

```sql
CREATE TABLE metrics_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pixel TEXT NOT NULL,
    interval_start TEXT NOT NULL,
    interval_end TEXT NOT NULL,
    parameters TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_attempt TEXT
);
```

---

## 3. Queries and Mutations (Logical Behavior)

Below, “now” means the current time in ISO 8601 UTC with fractional seconds.

### 3.1 Registration

- **Ensure pixel config**  
  Insert into `pixel_config` with `(pixel, aggregation_interval)` using conflict resolution that ignores (or replaces, depending on API). Default `aggregation_interval` is 3600 if not specified.

- **Register pixel**  
  Insert or replace one row in `pixel_config` with the given `aggregation_interval`.

- **Register buckets for a metric**  
  - Delete from `metric_buckets` where `pixel = ?` and `metric_name = ?`.  
  - If a non-null list of buckets is provided, insert one row per bucket with `ordinal` 0, 1, 2, … and the given `min_inclusive`, `max_exclusive`, `name`.

### 3.2 Mutation (counters and gauges)

Before any mutation, ensure the pixel exists in `pixel_config` (e.g. insert with default interval, ignore on conflict).

- **Increment counter**  
  Insert into `aggregated_metrics` with `(pixel, metric_type = 'counter', metric_name, value = amount, created_at = now, updated_at = now)`.  
  On conflict `(pixel, metric_name)`: set `value = value + amount`, `updated_at = now`.  
  Use the platform’s equivalent of SQLite `INSERT ... ON CONFLICT(pixel, metric_name) DO UPDATE ...`.

- **Set gauge**  
  Insert into `aggregated_metrics` with `(pixel, metric_type = 'gauge', metric_name, value, created_at = now, updated_at = now)`.  
  On conflict `(pixel, metric_name)`: set `value = excluded.value`, `updated_at = now`.

### 3.3 Collection (mature metrics → outbox)

Run in a single write transaction:

1. **Select mature metrics** (with bucket resolution) using the query in §3.4. A row is “mature” if `aggregated_metrics.created_at` is older than (now − pixel’s `aggregation_interval`).

2. **Group selected rows by `pixel`.**  
   For each pixel:
   - `interval_start` = minimum `created_at` among the selected rows for that pixel.  
   - `interval_end` = now (time of collection).  
   - Build `parameters` from all selected rows for that pixel (see §3.5).  
   If the group has no rows (e.g. all filtered out by bucketing), skip this pixel.

3. **Insert one row** into `metrics_outbox` per pixel with `(pixel, interval_start, interval_end, parameters, attempts = 0, last_attempt = NULL)`.

4. **Delete** from `aggregated_metrics` all rows whose `id` was in the selected mature set.

5. Return the number of outbox rows inserted.

### 3.4 Collection query (mature metrics with bucket resolution)

This query returns the rows that are eligible for collection and their resolved value (bucket name or stringified number). Implementations may use an equivalent query or multiple statements.

**Maturity condition:**  
`aggregated_metrics.created_at < (now − pixel_config.aggregation_interval)` (in seconds).

**Bucket resolution:**  
For each row, if there are buckets for `(pixel, metric_name)`:
- Find the bucket where `value >= min_inclusive` and (`max_exclusive` IS NULL or `value < max_exclusive`), ordering by `ordinal`, take the first match → use `name` as resolved value.
- If no bucket matches but at least one bucket exists for that metric → drop the row (resolved value NULL).
If there are no buckets for that metric → use `CAST(value AS TEXT)` as resolved value.

**SQL (SQLite) for the collection step:**

```sql
WITH mature AS (
  SELECT m.id, m.pixel, m.metric_type, m.metric_name, m.value, m.created_at
  FROM aggregated_metrics m
  JOIN pixel_config c ON m.pixel = c.pixel
  WHERE m.created_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-' || CAST(c.aggregation_interval AS TEXT) || ' seconds')
),
with_bucket AS (
  SELECT mature.*,
    (SELECT b.name FROM metric_buckets b
     WHERE b.pixel = mature.pixel AND b.metric_name = mature.metric_name
       AND mature.value >= b.min_inclusive
       AND (b.max_exclusive IS NULL OR mature.value < b.max_exclusive)
     ORDER BY b.ordinal LIMIT 1) AS bucket_name,
    EXISTS (SELECT 1 FROM metric_buckets b2 WHERE b2.pixel = mature.pixel AND b2.metric_name = mature.metric_name) AS has_buckets
  FROM mature
),
with_resolved AS (
  SELECT id, pixel, metric_type, metric_name, created_at,
    CASE
      WHEN bucket_name IS NOT NULL THEN bucket_name
      WHEN has_buckets THEN NULL
      ELSE CAST(value AS TEXT)
    END AS resolved_value
  FROM with_bucket
)
SELECT id, pixel, metric_type, metric_name, created_at, resolved_value
FROM with_resolved
WHERE resolved_value IS NOT NULL
```

Use the result to group by pixel, compute `interval_start` (min `created_at`), `interval_end` (now), and build `parameters` as in §3.5; then insert into `metrics_outbox` and delete the `aggregated_metrics` rows by `id`.

### 3.5 Parameters string (URL-encoded)

From the collected rows for one pixel, build a list of key-value pairs:

- **Key:** `{metric_type}_{metric_name}` (e.g. `counter_foo`, `gauge_bar`).
- **Value:** the resolved value (bucket name or stringified number).

Encode as application/x-www-form-urlencoded: key and value percent-encoded, pairs joined by `&`. Order does not need to be specified. Example: `counter_clicks=3&gauge_latency_ms=high`.

---

## 4. Public API

### 4.1 Types

- **CollectedPixel (pending entry)**  
  - `id` (integer): outbox row id; use for `markSent` / `markFailed`.  
  - `start` (datetime): interval start (ISO 8601 UTC).  
  - `end` (datetime): interval end (ISO 8601 UTC).  
  - `pixel` (string): pixel name.  
  - `parameters` (string): URL-encoded key-value pairs.

- **BucketRange (registration)**  
  - `minInclusive` (number): lower bound, inclusive.  
  - `maxExclusive` (number or null): upper bound, exclusive; null = no upper bound.  
  - `name` (string): label for this bucket.

### 4.2 Registration

- **registerPixel(pixel, aggregationInterval?)**  
  Upsert `pixel_config`. Default `aggregationInterval` 3600 (seconds).

- **registerCounter(pixel, name, buckets?)**  
  Ensure pixel exists; replace bucket definitions for this (pixel, name) with `buckets` (ordered by array index → `ordinal`). No-op for the metric row itself until first increment.

- **registerGauge(pixel, name, buckets?)**  
  Same as registerCounter but for gauge metrics.

### 4.3 Mutation

- **increment(pixel, name, by?)**  
  Add `by` (default 1) to the counter `(pixel, name)`. Insert row if missing; otherwise update `value` and `updated_at`.

- **set(pixel, name, value)**  
  Set gauge `(pixel, name)` to `value`. Insert or replace row and set `updated_at`.

### 4.4 Collection

- **collectMetrics() → integer**  
  In one transaction: select mature metrics (with bucket resolution), group by pixel, build `parameters`, insert one outbox row per pixel, delete collected rows from `aggregated_metrics`. Return number of outbox rows created.

### 4.5 Outbox

- **pendingPixels(limit?)**  
  Return up to `limit` (default 50) outbox rows ordered by `id` ascending, as CollectedPixel (`id`, `start`, `end`, `pixel`, `parameters`). `start`/`end` are parsed from `interval_start`/`interval_end`.

- **markSent(id)**  
  Delete the outbox row with the given `id`.

- **markFailed(id)**  
  For the outbox row with the given `id`: set `attempts = attempts + 1`, `last_attempt` = now.

- **purgeExpired(maxAttempts?)**  
  Delete outbox rows where `attempts > maxAttempts` (default 5). Return the number of rows deleted.

### 4.6 Housekeeping / testing

- **peek(pixel, name) → number | null**  
  Return current `value` for the row in `aggregated_metrics` with that `(pixel, metric_name)`, or null if absent.

- **reset()**  
  Delete all rows from `metrics_outbox`, `aggregated_metrics`, `metric_buckets`, `pixel_config` (order may matter for foreign keys; the reference implementation has no FKs on these tables). Intended for tests.

---

## 5. Metric types and semantics

- **counter:**  
  Metric type string `"counter"`. Values are summed on conflict (increment). At collection time the stored value is used (or bucketed); for unbucketed counters the value is typically an integer count.

- **gauge:**  
  Metric type string `"gauge"`. Values are replaced on conflict (set). Same bucketing and collection rules as counters.

---

## 6. Timestamp and encoding notes

- **Storage:** All datetime columns are stored as TEXT in ISO 8601 format: `YYYY-MM-DDTHH:MM:SS.ffffffZ` (UTC, optional fractional seconds).  
- **Parameters:** Keys and values in `parameters` must be percent-encoded for use in query strings; key format is `{metric_type}_{metric_name}`.

This spec, together with the schema and collection query above, is sufficient to reimplement the MetricsAggregator on other platforms with equivalent semantics.
