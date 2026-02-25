// Copyright 2025 DuckDuckGo. All rights reserved.
// Licensed under the Apache License, Version 2.0.

use rusqlite::{Connection, params};
use serde::Deserialize;
use std::collections::HashMap;
use std::ffi::CString;
use std::os::raw::{c_char, c_double, c_int, c_void};
use std::slice;
use std::str;

const METRIC_TYPE_COUNTER: &str = "counter";
const METRIC_TYPE_GAUGE: &str = "gauge";
const DEFAULT_AGGREGATION_INTERVAL: f64 = 3600.0;

const VALUE_TYPE_INT: &str = "int";
const VALUE_TYPE_DOUBLE: &str = "double";

const MIGRATION_V1: &str = "
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS pixel_config (
    pixel TEXT PRIMARY KEY,
    aggregation_interval REAL NOT NULL DEFAULT 3600
);
CREATE TABLE IF NOT EXISTS metric_buckets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pixel TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    min_inclusive REAL NOT NULL,
    max_exclusive REAL,
    name TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_metric_buckets_unique ON metric_buckets(pixel, metric_name, ordinal);
CREATE TABLE IF NOT EXISTS aggregated_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pixel TEXT NOT NULL,
    metric_type TEXT NOT NULL,
    metric_name TEXT NOT NULL,
    value REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_aggregated_metrics_unique ON aggregated_metrics(pixel, metric_name);
CREATE TABLE IF NOT EXISTS metrics_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pixel TEXT NOT NULL,
    interval_start TEXT NOT NULL,
    interval_end TEXT NOT NULL,
    parameters TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_attempt TEXT
);
";

const MIGRATION_V2: &str = "
CREATE TABLE IF NOT EXISTS _schema_version (version INTEGER NOT NULL);
INSERT OR IGNORE INTO _schema_version (version) VALUES (1);
";

const COLLECT_METRICS_SQL: &str = "
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
with_spec AS (
  SELECT with_bucket.*, COALESCE(s.value_type, 'int') AS value_type
  FROM with_bucket
  LEFT JOIN metric_spec s ON s.pixel = with_bucket.pixel AND s.metric_name = with_bucket.metric_name
),
with_resolved AS (
  SELECT id, pixel, metric_type, metric_name, created_at,
    bucket_name AS bucket_or_null, value, value_type, has_buckets
  FROM with_spec
)
SELECT id, pixel, metric_type, metric_name, created_at, bucket_or_null, value, value_type, has_buckets
FROM with_resolved
WHERE bucket_or_null IS NOT NULL OR NOT has_buckets
";

#[derive(Deserialize)]
struct BucketInput {
    min_inclusive: f64,
    max_exclusive: Option<f64>,
    name: String,
}

#[derive(Deserialize)]
struct MetricSpecInput {
    name: String,
    #[serde(rename = "type")]
    metric_type: String,
    buckets: Option<Vec<BucketInput>>,
    #[serde(rename = "value_type")]
    value_type: Option<String>,
}

struct MetricsAggregatorDb {
    conn: Connection,
    last_error: Option<String>,
}

impl MetricsAggregatorDb {
    fn set_err(&mut self, e: impl std::fmt::Display) {
        self.last_error = Some(e.to_string());
    }

    fn run_migration(conn: &Connection) -> rusqlite::Result<()> {
        conn.execute_batch(MIGRATION_V1)?;
        conn.execute_batch(MIGRATION_V2)?;
        let version: i64 = conn.query_row("SELECT COALESCE(MAX(version), 0) FROM _schema_version", [], |r| r.get(0))?;
        if version < 2 {
            let _ = conn.execute("ALTER TABLE pixel_config ADD COLUMN created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", []);
            conn.execute(
                "CREATE TABLE IF NOT EXISTS metric_spec (pixel TEXT NOT NULL, metric_name TEXT NOT NULL, metric_type TEXT NOT NULL, value_type TEXT NOT NULL DEFAULT 'int', PRIMARY KEY (pixel, metric_name))",
                [],
            )?;
            conn.execute("INSERT INTO _schema_version (version) VALUES (2)", [])?;
        }
        Ok(())
    }
}

fn ptr_to_string(ptr: *const c_char, len: usize) -> Option<String> {
    if ptr.is_null() || len == 0 {
        return None;
    }
    let slice = unsafe { slice::from_raw_parts(ptr as *const u8, len) };
    str::from_utf8(slice).map(String::from).ok()
}

fn alloc_c_string(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_open(path_ptr: *const c_char, path_len: usize) -> *mut c_void {
    let path = match ptr_to_string(path_ptr as *const c_char, path_len) {
        Some(p) => p,
        None => return std::ptr::null_mut(),
    };
    let conn = match Connection::open(&path) {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };
    if MetricsAggregatorDb::run_migration(&conn).is_err() {
        return std::ptr::null_mut();
    }
    let db = Box::new(MetricsAggregatorDb {
        conn,
        last_error: None,
    });
    Box::into_raw(db) as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_close(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let _ = Box::from_raw(handle as *mut MetricsAggregatorDb);
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = CString::from_raw(ptr);
}

fn with_handle<T>(handle: *mut c_void, f: impl FnOnce(&mut MetricsAggregatorDb) -> T) -> T {
    assert!(!handle.is_null());
    let db = unsafe { &mut *(handle as *mut MetricsAggregatorDb) };
    f(db)
}

fn register_aggregation_impl(
    conn: &Connection,
    pixel: &str,
    aggregation_interval: f64,
    created_at: &str,
    specs: &[MetricSpecInput],
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO pixel_config (pixel, aggregation_interval, created_at) VALUES (?1, ?2, ?3)",
        params![pixel, aggregation_interval, created_at],
    )?;
    for spec in specs {
        let value_type = spec.value_type.as_deref().unwrap_or(VALUE_TYPE_INT);
        conn.execute("DELETE FROM metric_buckets WHERE pixel = ?1 AND metric_name = ?2", params![pixel, spec.name])?;
        if let Some(ref buckets) = spec.buckets {
            let mut insert = conn.prepare(
                "INSERT INTO metric_buckets (pixel, metric_name, ordinal, min_inclusive, max_exclusive, name) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            for (ordinal, b) in buckets.iter().enumerate() {
                insert.execute(params![pixel, spec.name, ordinal as i32, b.min_inclusive, b.max_exclusive, b.name])?;
            }
        }
        conn.execute(
            "INSERT OR REPLACE INTO metric_spec (pixel, metric_name, metric_type, value_type) VALUES (?1, ?2, ?3, ?4)",
            params![pixel, spec.name, spec.metric_type, value_type],
        )?;
    }
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_register_aggregation(
    handle: *mut c_void,
    name_ptr: *const c_char,
    name_len: usize,
    aggregation_interval: c_double,
    created_at_ptr: *const c_char,
    created_at_len: usize,
    specs_json_ptr: *const c_char,
    specs_json_len: usize,
) -> c_int {
    let pixel = match ptr_to_string(name_ptr as *const c_char, name_len) {
        Some(p) => p,
        None => return -1,
    };
    let created_at = match ptr_to_string(created_at_ptr as *const c_char, created_at_len) {
        Some(s) => s,
        None => return -1,
    };
    let specs: Vec<MetricSpecInput> = if specs_json_ptr.is_null() || specs_json_len == 0 {
        vec![]
    } else {
        let json_str = match ptr_to_string(specs_json_ptr as *const c_char, specs_json_len) {
            Some(s) => s,
            None => return -1,
        };
        match serde_json::from_str(&json_str) {
            Ok(s) => s,
            Err(_e) => return -1,
        }
    };
    with_handle(handle, |db| {
        match register_aggregation_impl(&db.conn, &pixel, aggregation_interval, &created_at, &specs) {
            Ok(()) => 0,
            Err(e) => {
                db.set_err(e);
                -1
            }
        }
    })
}

fn ensure_metric_spec(conn: &Connection, pixel: &str, metric_name: &str, metric_type: &str) -> rusqlite::Result<()> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM metric_spec WHERE pixel = ?1 AND metric_name = ?2",
        params![pixel, metric_name],
        |r| r.get(0),
    )?;
    if count == 0 {
        conn.execute(
            "INSERT INTO metric_spec (pixel, metric_name, metric_type, value_type) VALUES (?1, ?2, ?3, ?4)",
            params![pixel, metric_name, metric_type, VALUE_TYPE_INT],
        )?;
    }
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_increment(
    handle: *mut c_void,
    pixel_ptr: *const c_char,
    pixel_len: usize,
    name_ptr: *const c_char,
    name_len: usize,
    by: c_double,
) -> c_int {
    let pixel = match ptr_to_string(pixel_ptr as *const c_char, pixel_len) {
        Some(p) => p,
        None => return -1,
    };
    let name = match ptr_to_string(name_ptr as *const c_char, name_len) {
        Some(n) => n,
        None => return -1,
    };
    with_handle(handle, |db| {
        db.conn
            .execute(
                "INSERT OR IGNORE INTO pixel_config (pixel, aggregation_interval, created_at) VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
                params![pixel, DEFAULT_AGGREGATION_INTERVAL],
            )
            .ok();
        if let Err(e) = ensure_metric_spec(&db.conn, &pixel, &name, METRIC_TYPE_COUNTER) {
            db.set_err(e);
            return -1;
        }
        db.conn
            .execute(
                "INSERT INTO aggregated_metrics (pixel, metric_type, metric_name, value, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                 ON CONFLICT(pixel, metric_name) DO UPDATE SET value = value + excluded.value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
                params![pixel, METRIC_TYPE_COUNTER, name, by],
            )
            .map(|_| 0)
            .unwrap_or_else(|e| {
                db.set_err(e);
                -1
            })
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_set(
    handle: *mut c_void,
    pixel_ptr: *const c_char,
    pixel_len: usize,
    name_ptr: *const c_char,
    name_len: usize,
    value: c_double,
) -> c_int {
    let pixel = match ptr_to_string(pixel_ptr as *const c_char, pixel_len) {
        Some(p) => p,
        None => return -1,
    };
    let name = match ptr_to_string(name_ptr as *const c_char, name_len) {
        Some(n) => n,
        None => return -1,
    };
    with_handle(handle, |db| {
        db.conn
            .execute(
                "INSERT OR IGNORE INTO pixel_config (pixel, aggregation_interval, created_at) VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
                params![pixel, DEFAULT_AGGREGATION_INTERVAL],
            )
            .ok();
        if let Err(e) = ensure_metric_spec(&db.conn, &pixel, &name, METRIC_TYPE_GAUGE) {
            db.set_err(e);
            return -1;
        }
        db.conn
            .execute(
                "INSERT INTO aggregated_metrics (pixel, metric_type, metric_name, value, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                 ON CONFLICT(pixel, metric_name) DO UPDATE SET value = excluded.value, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
                params![pixel, METRIC_TYPE_GAUGE, name, value],
            )
            .map(|_| 0)
            .unwrap_or_else(|e| {
                db.set_err(e);
                -1
            })
    })
}

fn format_resolved_value(bucket_or_null: Option<String>, value: f64, value_type: &str) -> String {
    match bucket_or_null {
        Some(b) => b,
        None => {
            if value_type == VALUE_TYPE_INT {
                format!("{}", value as i64)
            } else {
                value.to_string()
            }
        }
    }
}

fn collect_metrics_impl(conn: &Connection) -> rusqlite::Result<c_int> {
    let mut stmt = conn.prepare(COLLECT_METRICS_SQL)?;
    #[allow(clippy::type_complexity)]
    let rows: Vec<(i64, String, String, String, String, Option<String>, f64, String, i64)> = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, f64>(6)?,
                row.get::<_, String>(7)?,
                row.get::<_, i64>(8)?,
            ))
        })?
        .filter_map(|r| r.ok())
        .collect();
    if rows.is_empty() {
        return Ok(0);
    }
    let interval_end: String = conn.query_row(
        "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')",
        [],
        |r| r.get(0),
    )?;
    let mut by_pixel: HashMap<String, (String, Vec<(String, String)>)> = HashMap::new();
    let mut ids_to_delete = Vec::new();
    for (id, pixel, _metric_type, metric_name, created_at, bucket_or_null, value, value_type, _has_buckets) in &rows {
        ids_to_delete.push(*id);
        let resolved_value = format_resolved_value(bucket_or_null.clone(), *value, value_type);
        let entry = by_pixel
            .entry(pixel.clone())
            .or_insert_with(|| (created_at.clone(), Vec::new()));
        if created_at < &entry.0 {
            entry.0 = created_at.clone();
        }
        entry.1.push((metric_name.clone(), resolved_value));
    }
    let tx = conn.unchecked_transaction()?;
    let mut outbox_count: c_int = 0;
    for (pixel, (interval_start, items)) in by_pixel {
        if items.is_empty() {
            continue;
        }
        let params_str = urlencode_params(&items);
        tx.execute(
            "INSERT INTO metrics_outbox (pixel, interval_start, interval_end, parameters, attempts, last_attempt) VALUES (?1, ?2, ?3, ?4, 0, NULL)",
            params![pixel, interval_start, interval_end, params_str],
        )?;
        outbox_count += 1;
    }
    if !ids_to_delete.is_empty() {
        let placeholders = ids_to_delete.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
        let sql = format!("DELETE FROM aggregated_metrics WHERE id IN ({})", placeholders);
        tx.execute(&sql, rusqlite::params_from_iter(ids_to_delete.iter()))?;
    }
    tx.commit()?;
    Ok(outbox_count)
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_collect_metrics(handle: *mut c_void) -> c_int {
    with_handle(handle, |db| {
        match collect_metrics_impl(&db.conn) {
            Ok(n) => n,
            Err(e) => {
                db.set_err(e);
                -1
            }
        }
    })
}

fn urlencode_params(items: &[(String, String)]) -> String {
    items
        .iter()
        .map(|(k, v)| format!("{}={}", urlencoding::encode(k), urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn pending_pixels_impl(conn: &Connection, limit: i32) -> rusqlite::Result<Vec<serde_json::Value>> {
    let mut stmt = conn.prepare(
        "SELECT id, pixel, interval_start, interval_end, parameters FROM metrics_outbox ORDER BY id ASC LIMIT ?1",
    )?;
    let entries: Vec<serde_json::Value> = stmt
        .query_map([limit], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?
        .filter_map(|r| r.ok())
        .map(|(id, pixel, interval_start, interval_end, parameters)| {
            serde_json::json!({
                "id": id,
                "pixel": pixel,
                "interval_start": interval_start,
                "interval_end": interval_end,
                "parameters": parameters
            })
        })
        .collect();
    Ok(entries)
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_pending_pixels(handle: *mut c_void, limit: c_int) -> *mut c_char {
    with_handle(handle, |db| {
        let limit = limit.max(0) as i32;
        let entries = match pending_pixels_impl(&db.conn, limit) {
            Ok(entries) => entries,
            Err(e) => {
                db.set_err(e);
                return std::ptr::null_mut();
            }
        };
        match serde_json::to_string(&entries) {
            Ok(json) => alloc_c_string(&json),
            Err(e) => {
                db.set_err(e);
                std::ptr::null_mut()
            }
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_mark_sent(handle: *mut c_void, id: i64) -> c_int {
    with_handle(handle, |db| {
        db.conn
            .execute("DELETE FROM metrics_outbox WHERE id = ?1", [id])
            .map(|_| 0)
            .unwrap_or_else(|e| {
                db.set_err(e);
                -1
            })
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_mark_failed(handle: *mut c_void, id: i64) -> c_int {
    with_handle(handle, |db| {
        db.conn
            .execute(
                "UPDATE metrics_outbox SET attempts = attempts + 1, last_attempt = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?1",
                [id],
            )
            .map(|_| 0)
            .unwrap_or_else(|e| {
                db.set_err(e);
                -1
            })
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_purge_expired(handle: *mut c_void, max_attempts: c_int) -> c_int {
    with_handle(handle, |db| {
        let n = db
            .conn
            .execute("DELETE FROM metrics_outbox WHERE attempts > ?1", [max_attempts])
            .unwrap_or_else(|e| {
                db.set_err(e);
                0
            });
        n as c_int
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_peek(
    handle: *mut c_void,
    pixel_ptr: *const c_char,
    pixel_len: usize,
    name_ptr: *const c_char,
    name_len: usize,
    out_value: *mut c_double,
) -> c_int {
    if out_value.is_null() {
        return -1;
    }
    let pixel = match ptr_to_string(pixel_ptr as *const c_char, pixel_len) {
        Some(p) => p,
        None => return -1,
    };
    let name = match ptr_to_string(name_ptr as *const c_char, name_len) {
        Some(n) => n,
        None => return -1,
    };
    with_handle(handle, |db| {
        match db.conn.query_row(
            "SELECT value FROM aggregated_metrics WHERE pixel = ?1 AND metric_name = ?2",
            params![pixel, name],
            |r| r.get::<_, f64>(0),
        ) {
            Ok(v) => {
                *out_value = v;
                1
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => 0,
            Err(e) => {
                db.set_err(e);
                -1
            }
        }
    })
}

fn prune_aggregations_impl(conn: &Connection, interval_seconds: f64) -> rusqlite::Result<c_int> {
    let max_created: Option<String> = conn.query_row(
        "SELECT MAX(created_at) FROM pixel_config",
        [],
        |r| r.get(0),
    ).ok();
    let Some(ref max_created) = max_created else {
        return Ok(0);
    };
    let interval_str = interval_seconds.to_string();
    let cutoff: Option<String> = conn.query_row(
        "SELECT datetime(?1, '-' || ?2 || ' seconds')",
        params![max_created, interval_str],
        |r| r.get(0),
    ).ok();
    let Some(ref cutoff) = cutoff else {
        return Ok(0);
    };
    conn.execute("DELETE FROM metric_buckets WHERE pixel IN (SELECT pixel FROM pixel_config WHERE created_at < ?1)", [cutoff])?;
    conn.execute("DELETE FROM aggregated_metrics WHERE pixel IN (SELECT pixel FROM pixel_config WHERE created_at < ?1)", [cutoff])?;
    conn.execute("DELETE FROM metric_spec WHERE pixel IN (SELECT pixel FROM pixel_config WHERE created_at < ?1)", [cutoff])?;
    let n = conn.execute("DELETE FROM pixel_config WHERE created_at < ?1", [cutoff])?;
    Ok(n as c_int)
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_prune_aggregations(handle: *mut c_void, interval_seconds: c_double) -> c_int {
    with_handle(handle, |db| {
        match prune_aggregations_impl(&db.conn, interval_seconds) {
            Ok(n) => n,
            Err(e) => {
                db.set_err(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_reset(handle: *mut c_void) -> c_int {
    with_handle(handle, |db| {
        db.conn.execute("DELETE FROM metrics_outbox", []).ok();
        db.conn.execute("DELETE FROM aggregated_metrics", []).ok();
        db.conn.execute("DELETE FROM metric_buckets", []).ok();
        db.conn.execute("DELETE FROM metric_spec", []).ok();
        db.conn.execute("DELETE FROM pixel_config", []).ok();
        0
    })
}

#[no_mangle]
pub unsafe extern "C" fn ddg_ma_last_error_message(handle: *mut c_void) -> *mut c_char {
    with_handle(handle, |db| {
        db.last_error
            .as_deref()
            .map(alloc_c_string)
            .unwrap_or(std::ptr::null_mut())
    })
}
