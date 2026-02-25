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

Configures each aggregation (pixel) and its aggregation interval. `created_at` is used for pruning relative to the latest aggregation (e.g. after a device restores an old session).

| Column                 | Type    | Constraints        | Description |
|------------------------|---------|--------------------|-------------|
| `pixel`                | TEXT    | PRIMARY KEY        | Aggregation (pixel) identifier. |
| `aggregation_interval` | REAL    | NOT NULL, DEFAULT 3600 | Seconds after which metrics for this aggregation are considered mature for collection. |
| `created_at`           | TEXT    | NOT NULL           | ISO 8601 UTC when the aggregation was registered; used for pruning. |

**DDL (SQLite):**

```sql
CREATE TABLE pixel_config (
    pixel TEXT PRIMARY KEY,
    aggregation_interval REAL NOT NULL DEFAULT 3600,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
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

### 2.3 Table: `metric_spec`

Per-(pixel, metric_name) spec: type (counter/gauge) and value type (int/double). Used at collection to format values (integers emitted without decimal when value_type is `int`).

| Column        | Type    | Constraints   | Description |
|---------------|---------|---------------|-------------|
| `pixel`       | TEXT    | NOT NULL      | Aggregation identifier. |
| `metric_name`| TEXT    | NOT NULL      | Metric name. |
| `metric_type`| TEXT    | NOT NULL      | Either `"counter"` or `"gauge"`. |
| `value_type` | TEXT    | NOT NULL DEFAULT 'int' | Either `"int"` or `"double"`; controls how the value is emitted in parameters. |

**Primary key:** `(pixel, metric_name)`.

**DDL (SQLite):**

```sql
CREATE TABLE metric_spec (
    pixel TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    metric_type TEXT NOT NULL,
    value_type TEXT NOT NULL DEFAULT 'int',
    PRIMARY KEY (pixel, metric_name)
);
```

### 2.4 Table: `aggregated_metrics`

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

### 2.5 Table: `metrics_outbox`

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

- **Register aggregation**  
  Insert or replace one row in `pixel_config` with `(pixel, aggregation_interval, created_at)` where `created_at` is the time of registration (e.g. now in ISO 8601 UTC). For each metric in the provided metrics spec: ensure a row in `metric_spec` with `(pixel, metric_name, metric_type, value_type)`; replace bucket definitions for that metric in `metric_buckets` (delete existing, then insert one row per bucket with `ordinal` 0, 1, 2, …). Metrics are fully specified at registration (counters and gauges with optional buckets and value type int/double).

- **Auto-created specs**  
  If a mutation (increment/set) is performed for a (pixel, metric_name) with no `metric_spec` row, the implementation may insert a default spec (e.g. counter/int for increment, gauge/int for set) so that dynamic metric names work without pre-registration.

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
If there are no buckets for that metric → use the numeric value; when `metric_spec.value_type` is `int`, emit as an integer (no decimal); otherwise emit as a string representation of the number.

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

- **Key:** `metric_name` (the metric name only).
- **Value:** the resolved value (bucket name or stringified number).

Encode as application/x-www-form-urlencoded: key and value percent-encoded, pairs joined by `&`. Order does not need to be specified. Example: `clicks=3&latency_ms=high`.

---

## 4. Public API

### 4.1 Types

- **CollectedPixel (pending entry)**  
  - `id` (integer): outbox row id; use for `markSent` / `markFailed`.  
  - `start` (datetime): interval start (ISO 8601 UTC).  
  - `end` (datetime): interval end (ISO 8601 UTC).  
  - `pixel` (string): aggregation (pixel) name.  
  - `parameters` (string): URL-encoded key-value pairs.

- **BucketRange (registration)**  
  - `minInclusive` (number): lower bound, inclusive.  
  - `maxExclusive` (number or null): upper bound, exclusive; null = no upper bound.  
  - `name` (string): label for this bucket.

- **MetricSpec (registration)**  
  - `name` (string): metric name.  
  - `type`: `"counter"` or `"gauge"`.  
  - `buckets` (optional): array of `BucketRange` for bucketed output.  
  - `valueType` (optional): `"int"` (default) or `"double"`; when `int`, collected parameters emit the value as an integer.

### 4.2 Registration

- **registerAggregation(name, aggregationInterval, metricsSpecs)**  
  Register an aggregation with the given name and interval. Store `created_at` (e.g. now) in `pixel_config` for pruning. `metricsSpecs` is an array of `MetricSpec` defining all metrics (counters and gauges) with optional buckets and value type. Replaces any existing config and bucket/spec rows for this aggregation.

### 4.3 Mutation

- **increment(aggregationName, metricName, by?)**  
  Add `by` (default 1) to the counter for `(aggregationName, metricName)`. Insert row if missing; otherwise update `value` and `updated_at`. The aggregation and metric spec may be auto-created if not yet registered.

- **set(aggregationName, metricName, value)**  
  Set gauge `(aggregationName, metricName)` to `value`. Insert or replace row and set `updated_at`. The aggregation and metric spec may be auto-created if not yet registered.

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

- **pruneAggregations(olderThanInterval)**  
  Delete aggregations whose `created_at` is older than `(max(created_at) in pixel_config) − olderThanInterval`. Removes corresponding rows from `metric_buckets`, `aggregated_metrics`, `metric_spec`, and `pixel_config`. Use to remove old specs after a device restores an old session. Returns the number of aggregations (pixel_config rows) deleted.

### 4.6 Housekeeping / testing

- **peek(aggregationName, metricName) → number | null**  
  Return current `value` for the row in `aggregated_metrics` with that `(pixel, metric_name)`, or null if absent.

- **reset()**  
  Delete all rows from `metrics_outbox`, `aggregated_metrics`, `metric_buckets`, `metric_spec`, `pixel_config`. Intended for tests.

---

## 5. Metric types and semantics

- **counter:**  
  Metric type string `"counter"`. Values are summed on conflict (increment). At collection time the stored value is used (or bucketed); for unbucketed counters the value is typically an integer count.

- **gauge:**  
  Metric type string `"gauge"`. Values are replaced on conflict (set). Same bucketing and collection rules as counters.

---

## 6. Timestamp and encoding notes

- **Storage:** All datetime columns are stored as TEXT in ISO 8601 format: `YYYY-MM-DDTHH:MM:SS.ffffffZ` (UTC, optional fractional seconds).  
- **Parameters:** Keys and values in `parameters` must be percent-encoded for use in query strings; each key is the metric name (no metric_type prefix).

This spec, together with the schema and collection query above, is sufficient to reimplement the MetricsAggregator on other platforms with equivalent semantics.
