// DuckDuckGo Metrics Aggregator - C ABI
// Auto-generated. Do not edit by hand. Regenerate with: cbindgen --config cbindgen.toml --crate metrics_aggregator --output include/MetricsAggregatorRust.h

#ifndef DDG_METRICS_AGGREGATOR_H
#define DDG_METRICS_AGGREGATOR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Open database at path (UTF-8, path_len bytes). Returns opaque handle or NULL on error. */
void *ddg_ma_open(const char *path_ptr, size_t path_len);

/** Close and free the handle. No-op if handle is NULL. */
void ddg_ma_close(void *handle);

/** Free a string returned by the library (e.g. ddg_ma_pending_pixels, ddg_ma_last_error_message). */
void ddg_ma_free_string(char *ptr);

/** Register an aggregation with name, interval, created_at (ISO8601 UTF-8), and metrics specs JSON. Returns 0 on success, -1 on error. */
int ddg_ma_register_aggregation(void *handle, const char *name_ptr, size_t name_len, double aggregation_interval,
    const char *created_at_ptr, size_t created_at_len, const char *specs_json_ptr, size_t specs_json_len);

/** Increment a counter. Returns 0 on success, -1 on error. */
int ddg_ma_increment(void *handle, const char *pixel_ptr, size_t pixel_len, const char *name_ptr, size_t name_len, double by);

/** Set a gauge value. Returns 0 on success, -1 on error. */
int ddg_ma_set(void *handle, const char *pixel_ptr, size_t pixel_len, const char *name_ptr, size_t name_len, double value);

/** Collect mature metrics into outbox. Returns count of outbox rows created, or -1 on error. */
int ddg_ma_collect_metrics(void *handle);

/** Return JSON array of pending outbox entries (id, interval_start, interval_end, pixel, parameters). Caller must ddg_ma_free_string. NULL on error. */
char *ddg_ma_pending_pixels(void *handle, int limit);

/** Mark outbox entry as sent (delete). Returns 0 on success, -1 on error. */
int ddg_ma_mark_sent(void *handle, int64_t id);

/** Mark outbox entry as failed (increment attempts). Returns 0 on success, -1 on error. */
int ddg_ma_mark_failed(void *handle, int64_t id);

/** Delete outbox entries with attempts > max_attempts. Returns deleted count, or -1 on error. */
int ddg_ma_purge_expired(void *handle, int max_attempts);

/** Prune aggregations whose created_at is older than (max(created_at) - interval_seconds). Returns count of rows deleted, or -1 on error. */
int ddg_ma_prune_aggregations(void *handle, double interval_seconds);

/** Peek current value. out_value must be non-NULL. Returns 1 if value written, 0 if no row, -1 on error. */
int ddg_ma_peek(void *handle, const char *pixel_ptr, size_t pixel_len, const char *name_ptr, size_t name_len, double *out_value);

/** Delete all data (for tests). Returns 0. */
int ddg_ma_reset(void *handle);

/** Last error message for the handle (for logging). Caller must ddg_ma_free_string. NULL if no error. */
char *ddg_ma_last_error_message(void *handle);

#ifdef __cplusplus
}
#endif

#endif /* DDG_METRICS_AGGREGATOR_H */
