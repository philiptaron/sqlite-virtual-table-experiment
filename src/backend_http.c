/*
 * A backend that talks to the metadata service (server/nixremote-server)
 * over HTTP (backend='http://host:port'). Every request is a JSON POST:
 *
 *   /v1/query   {"table": T, "col": C, "op": "eq"|"ge"|"gt"|null, "arg": V,
 *                "order": bool, "limit": N|null}
 *               -> {"rows": [[...], ...]}
 *   /v1/commit  {"ops": [{"op": "insert", "table": T, "cols": [...]},
 *                        {"op": "update", "table": T, "id": N, "cols": [...]},
 *                        {"op": "delete", "table": T, "id": N}]}
 *               -> {}
 *
 * Failures are {"error": "..."} with status 409 when another host changed
 * something the transaction relied on (SQLITE_BUSY, so Nix retries the
 * whole transaction), 422 for a constraint violation, anything else hard.
 *
 * Writes are buffered and sent as one commit from xSync, so a transaction
 * costs no round trips beyond its reads. That works because ValidPaths ids
 * come from nr_path_id(): Nix gets a new path's id from last_insert_rowid()
 * right away, long before the server sees the row. Reads inside the
 * transaction see its own ValidPaths writes, since Nix looks up paths it
 * has just registered; any other read after a write in one transaction is
 * refused, as Nix never makes one.
 *
 * JSON is parsed and quoted by SQLite's JSON functions, run on a private
 * in-memory database that also holds the pending ValidPaths rows.
 */
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <curl/curl.h>
#include <string.h>

#include "backend.h"

#define FIRST_PAGE 16
#define MAX_PAGE 4096

typedef struct {
  nr_backend base;
  char *url;                  /* without a trailing slash */
  CURL *curl;
  struct curl_slist *headers;
  sqlite3 *mem;
  sqlite3_stmt *quote;        /* select json_quote(?1) */
  int in_txn;
  sqlite3_str *ops;           /* the pending commit's ops, comma separated */
  int nops;
  unsigned written;           /* bit i: nr_tables[i] was written in this transaction */
  int deleted;                /* ...and a ValidPaths row was deleted, cascading */
  sqlite3_int64 next_rowid;   /* for Refs and DerivationOutputs, whose rowids Nix ignores */
} http_backend;

typedef struct {
  nr_rows base;
  sqlite3_stmt *stmt;         /* on mem: over pending rows, or json_each over a response */
  /* Paging through a scan ordered by column col (col < 0: not paging). */
  const struct nr_table *table;
  int col;
  int limit;                  /* rows asked for in the current page */
  int count;                  /* rows seen so far in the current page */
  char *last;                 /* value of col in the last row seen */
} http_rows;

static const char mem_schema[] =
  "create table pending (id integer primary key, path text unique, hash, registrationTime,"
  "  deriver, narSize, ultimate, sigs, ca);"
  "create table deleted (id integer primary key);";

static unsigned table_bit(const struct nr_table *t) {
  for (int i = 0; i < 3; i++)
    if (nr_tables[i] == t)
      return 1u << i;
  return 0;
}

static int mem_fail(http_backend *h, int rc) {
  return nr_fail(&h->base, rc, "%s", sqlite3_errmsg(h->mem));
}

/* Append v (or, if v is NULL, text) to s as a JSON literal. */
static void append_json(http_backend *h, sqlite3_str *s, sqlite3_value *v, const char *text) {
  if (v)
    sqlite3_bind_value(h->quote, 1, v);
  else
    sqlite3_bind_text(h->quote, 1, text, -1, SQLITE_STATIC);
  if (sqlite3_step(h->quote) == SQLITE_ROW)
    sqlite3_str_appendall(s, (const char *)sqlite3_column_text(h->quote, 0));
  else
    sqlite3_str_appendall(s, "null");
  sqlite3_reset(h->quote);
  sqlite3_clear_bindings(h->quote);
}

static void append_cols(http_backend *h, sqlite3_str *s, const struct nr_table *t, sqlite3_value **cols) {
  sqlite3_str_appendall(s, "[");
  for (int i = 0; i < t->ncols; i++) {
    if (i)
      sqlite3_str_appendall(s, ",");
    append_json(h, s, cols[i], NULL);
  }
  sqlite3_str_appendall(s, "]");
}

static size_t on_body(char *data, size_t size, size_t n, void *userdata) {
  sqlite3_str_append(userdata, data, (int)(size * n));
  return size * n;
}

/* The "error" member of a failure response, or the response itself. */
static char *error_message(http_backend *h, const char *body) {
  sqlite3_stmt *stmt;
  char *msg = NULL;
  if (body && sqlite3_prepare_v2(h->mem, "select json_extract(?1, '$.error')", -1, &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, body, -1, SQLITE_STATIC);
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_text(stmt, 0))
      msg = sqlite3_mprintf("%s", sqlite3_column_text(stmt, 0));
    sqlite3_finalize(stmt);
  }
  return msg ? msg : sqlite3_mprintf("%.200s", body ? body : "empty response");
}

/* POST body (which this takes ownership of) to the service; on success
 * *response is the response body, to be freed with sqlite3_free. */
static int post(http_backend *h, const char *path, char *body, char **response) {
  char *url = sqlite3_mprintf("%s%s", h->url, path);
  sqlite3_str *received = sqlite3_str_new(NULL);
  curl_easy_setopt(h->curl, CURLOPT_URL, url);
  curl_easy_setopt(h->curl, CURLOPT_POSTFIELDS, body ? body : "{}");
  curl_easy_setopt(h->curl, CURLOPT_POSTFIELDSIZE, (long)(body ? strlen(body) : 2));
  curl_easy_setopt(h->curl, CURLOPT_WRITEDATA, received);
  CURLcode cc = curl_easy_perform(h->curl);
  long status = 0;
  curl_easy_getinfo(h->curl, CURLINFO_RESPONSE_CODE, &status);
  char *text = sqlite3_str_finish(received);
  sqlite3_free(body);

  int rc = SQLITE_OK;
  if (cc != CURLE_OK) {
    rc = nr_fail(&h->base, SQLITE_IOERR, "%s: %s", url, curl_easy_strerror(cc));
  } else if (status != 200) {
    char *msg = error_message(h, text);
    rc = nr_fail(&h->base, status == 409 ? SQLITE_BUSY : status == 422 ? SQLITE_CONSTRAINT : SQLITE_ERROR,
                 "%s (HTTP %ld from %s)", msg, status, url);
    sqlite3_free(msg);
  }
  sqlite3_free(url);
  if (rc == SQLITE_OK)
    *response = text ? text : sqlite3_mprintf("{}");
  else
    sqlite3_free(text);
  return rc;
}

/* Replace rows->stmt with one over the rows of a /v1/query response. */
static int fetch(http_backend *h, http_rows *rows, const char *op, int col, sqlite3_value *arg,
                 const char *arg_text, int order, int limit) {
  const struct nr_table *t = rows->table;
  sqlite3_str *req = sqlite3_str_new(NULL);
  sqlite3_str_appendf(req, "{\"table\":\"%s\",\"col\":", t->name);
  if (col >= 0)
    sqlite3_str_appendf(req, "\"%s\"", t->cols[col]);
  else
    sqlite3_str_appendall(req, "null");
  if (op) {
    sqlite3_str_appendf(req, ",\"op\":\"%s\",\"arg\":", op);
    append_json(h, req, arg, arg_text);
  }
  sqlite3_str_appendf(req, ",\"order\":%s", order ? "true" : "false");
  if (limit)
    sqlite3_str_appendf(req, ",\"limit\":%d", limit);
  sqlite3_str_appendall(req, "}");

  char *response;
  int rc = post(h, "/v1/query", sqlite3_str_finish(req), &response);
  if (rc != SQLITE_OK)
    return rc;

  sqlite3_str *sql = sqlite3_str_new(NULL);
  sqlite3_str_appendall(sql, "select ");
  for (int i = 0; i < t->ncols; i++)
    sqlite3_str_appendf(sql, "%sjson_extract(value, '$[%d]')", i ? ", " : "", i);
  sqlite3_str_appendall(sql, " from json_each(?1, '$.rows')");
  char *text = sqlite3_str_finish(sql);
  sqlite3_finalize(rows->stmt);
  rc = sqlite3_prepare_v2(h->mem, text, -1, &rows->stmt, NULL);
  sqlite3_free(text);
  if (rc != SQLITE_OK) {
    sqlite3_free(response);
    return mem_fail(h, rc);
  }
  sqlite3_bind_text(rows->stmt, 1, response, -1, sqlite3_free);
  rows->limit = limit;
  rows->count = 0;
  return SQLITE_OK;
}

static int new_rows(http_backend *h, const struct nr_table *t, http_rows **out) {
  http_rows *rows = sqlite3_malloc(sizeof *rows);
  if (!rows)
    return SQLITE_NOMEM;
  memset(rows, 0, sizeof *rows);
  rows->base.backend = &h->base;
  rows->table = t;
  rows->col = -1;
  *out = rows;
  return SQLITE_OK;
}

/* Rows of the transaction's own ValidPaths writes where cols[col] = arg. */
static int pending_rows(http_backend *h, int col, sqlite3_value *arg, http_rows *rows) {
  sqlite3_str *sql = sqlite3_str_new(NULL);
  sqlite3_str_appendall(sql, "select ");
  for (int i = 0; i < nr_valid_paths.ncols; i++)
    sqlite3_str_appendf(sql, "%s%s", i ? ", " : "", nr_valid_paths.cols[i]);
  if (col >= 0)
    sqlite3_str_appendf(sql, " from pending where %s = ?1", nr_valid_paths.cols[col]);
  else
    sqlite3_str_appendall(sql, " from pending where 0");
  char *text = sqlite3_str_finish(sql);
  int rc = sqlite3_prepare_v2(h->mem, text, -1, &rows->stmt, NULL);
  sqlite3_free(text);
  if (rc != SQLITE_OK)
    return mem_fail(h, rc);
  if (col >= 0)
    sqlite3_bind_value(rows->stmt, 1, arg);
  return SQLITE_OK;
}

static int mem_exists(http_backend *h, const char *sql, sqlite3_value *arg, sqlite3_int64 id) {
  sqlite3_stmt *stmt;
  int found = 0;
  if (sqlite3_prepare_v2(h->mem, sql, -1, &stmt, NULL) == SQLITE_OK) {
    if (arg)
      sqlite3_bind_value(stmt, 1, arg);
    else
      sqlite3_bind_int64(stmt, 1, id);
    found = sqlite3_step(stmt) == SQLITE_ROW;
    sqlite3_finalize(stmt);
  }
  return found;
}

/*
 * Serve an equality lookup on ValidPaths from the transaction's own writes
 * when it touches them: *served is set if rows now holds the answer (the
 * pending row, or nothing for a path deleted in this transaction).
 */
static int overlay(http_backend *h, int col, sqlite3_value *arg, http_rows *rows, int *served) {
  static const char *const has_pending[] = {
    "select 1 from pending where id = ?1", "select 1 from pending where path = ?1",
  };
  *served = 0;
  if (mem_exists(h, has_pending[col], arg, 0)) {
    *served = 1;
    return pending_rows(h, col, arg, rows);
  }
  sqlite3_int64 id = col == 0 ? sqlite3_value_int64(arg)
                              : nr_path_id((const char *)sqlite3_value_text(arg));
  if (id >= 0 && mem_exists(h, "select 1 from deleted where id = ?1", NULL, id)) {
    *served = 1;
    return pending_rows(h, -1, NULL, rows);
  }
  return SQLITE_OK;
}

static int http_query(nr_backend *base, const struct nr_table *t, enum nr_op op, int col,
                      sqlite3_value *arg, nr_rows **out) {
  http_backend *h = (http_backend *)base;
  http_rows *rows;
  int rc = new_rows(h, t, &rows);
  if (rc != SQLITE_OK)
    return rc;

  if (h->in_txn && (h->written & table_bit(t) || h->deleted)) {
    int served = 0;
    if (t == &nr_valid_paths && op == NR_EQ)
      rc = overlay(h, col, arg, rows, &served);
    else
      rc = nr_fail(base, SQLITE_ERROR, "reading %s after writing in the same transaction is not supported", t->name);
    if (rc != SQLITE_OK || served) {
      if (rc == SQLITE_OK)
        *out = &rows->base;
      else
        nr_rows_close(&rows->base);
      return rc;
    }
  }

  int ordered = -1;
  for (int i = 0; i < t->ncols; i++)
    if (t->ordered & 1u << i) {
      ordered = i;
      break;
    }
  if (op == NR_EQ) {
    rc = fetch(h, rows, "eq", col, arg, NULL, 0, 0);
  } else if (op == NR_GE) {
    rows->col = col;
    rc = fetch(h, rows, "ge", col, arg, NULL, 1, FIRST_PAGE);
  } else if (ordered >= 0) {
    rows->col = ordered;
    rc = fetch(h, rows, NULL, ordered, NULL, NULL, 1, FIRST_PAGE);
  } else {
    rc = fetch(h, rows, NULL, -1, NULL, NULL, 0, 0);
  }
  if (rc != SQLITE_OK) {
    nr_rows_close(&rows->base);
    return rc;
  }
  *out = &rows->base;
  return SQLITE_OK;
}

static int http_rows_next(nr_rows *base) {
  http_rows *rows = (http_rows *)base;
  http_backend *h = (http_backend *)base->backend;
  for (;;) {
    int rc = sqlite3_step(rows->stmt);
    if (rc == SQLITE_ROW) {
      if (rows->col >= 0) {
        rows->count++;
        sqlite3_free(rows->last);
        rows->last = sqlite3_mprintf("%s", sqlite3_column_text(rows->stmt, rows->col));
      }
      return SQLITE_ROW;
    }
    if (rc != SQLITE_DONE)
      return nr_fail(&h->base, rc, "reading response: %s", sqlite3_errmsg(h->mem));
    if (rows->col < 0 || rows->count < rows->limit)
      return SQLITE_DONE;
    /* A full page: ask for the rows after the last one seen. */
    int limit = rows->limit * 2 > MAX_PAGE ? MAX_PAGE : rows->limit * 2;
    rc = fetch(h, rows, "gt", rows->col, NULL, rows->last, 1, limit);
    if (rc != SQLITE_OK)
      return rc;
  }
}

static sqlite3_value *http_rows_column(nr_rows *base, int col) {
  return sqlite3_column_value(((http_rows *)base)->stmt, col);
}

static void http_rows_close(nr_rows *base) {
  http_rows *rows = (http_rows *)base;
  sqlite3_finalize(rows->stmt);
  sqlite3_free(rows->last);
  sqlite3_free(rows);
}

/* Start the next op in the pending commit. */
static sqlite3_str *add_op(http_backend *h, const char *op, const struct nr_table *t) {
  if (!h->ops)
    h->ops = sqlite3_str_new(NULL);
  sqlite3_str_appendf(h->ops, "%s{\"op\":\"%s\",\"table\":\"%s\"", h->nops++ ? "," : "", op, t->name);
  h->written |= table_bit(t);
  return h->ops;
}

/* Record a ValidPaths row as this transaction left it. */
static int put_pending(http_backend *h, sqlite3_int64 id, sqlite3_value **cols) {
  sqlite3_stmt *stmt;
  int rc = sqlite3_prepare_v2(h->mem, "insert or replace into pending values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                              -1, &stmt, NULL);
  if (rc != SQLITE_OK)
    return mem_fail(h, rc);
  sqlite3_bind_int64(stmt, 1, id);
  for (int i = 1; i < nr_valid_paths.ncols; i++)
    sqlite3_bind_value(stmt, i + 1, cols[i]);
  rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE)
    return mem_fail(h, rc);
  return SQLITE_OK;
}

static int mem_exec_id(http_backend *h, const char *sql, sqlite3_int64 id) {
  sqlite3_stmt *stmt;
  int rc = sqlite3_prepare_v2(h->mem, sql, -1, &stmt, NULL);
  if (rc != SQLITE_OK)
    return mem_fail(h, rc);
  sqlite3_bind_int64(stmt, 1, id);
  rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  return rc == SQLITE_DONE ? SQLITE_OK : mem_fail(h, rc);
}

static int require_txn(http_backend *h) {
  return h->in_txn ? SQLITE_OK : nr_fail(&h->base, SQLITE_MISUSE, "write outside a transaction");
}

static int http_insert(nr_backend *base, const struct nr_table *t, sqlite3_value **cols,
                       sqlite3_int64 *rowid) {
  http_backend *h = (http_backend *)base;
  int rc = require_txn(h);
  if (rc != SQLITE_OK)
    return rc;
  sqlite3_int64 id = ++h->next_rowid;
  if (t->rowid_col >= 0) {
    id = nr_path_id((const char *)sqlite3_value_text(cols[1]));
    if (id < 0)
      return nr_fail(base, SQLITE_CONSTRAINT, "\"%s\" is not a store path", sqlite3_value_text(cols[1]));
    if ((rc = put_pending(h, id, cols)) != SQLITE_OK ||
        (rc = mem_exec_id(h, "delete from deleted where id = ?1", id)) != SQLITE_OK)
      return rc;
  }
  sqlite3_str *s = add_op(h, "insert", t);
  sqlite3_str_appendall(s, ",\"cols\":");
  append_cols(h, s, t, cols);
  sqlite3_str_appendall(s, "}");
  *rowid = id;
  return SQLITE_OK;
}

static int http_update(nr_backend *base, const struct nr_table *t, sqlite3_int64 rowid,
                       sqlite3_value **cols) {
  http_backend *h = (http_backend *)base;
  int rc = require_txn(h);
  if (rc != SQLITE_OK || (rc = put_pending(h, rowid, cols)) != SQLITE_OK)
    return rc;
  sqlite3_str *s = add_op(h, "update", t);
  sqlite3_str_appendf(s, ",\"id\":%lld,\"cols\":", rowid);
  append_cols(h, s, t, cols);
  sqlite3_str_appendall(s, "}");
  return SQLITE_OK;
}

static int http_delete(nr_backend *base, const struct nr_table *t, sqlite3_int64 rowid) {
  http_backend *h = (http_backend *)base;
  int rc = require_txn(h);
  if (rc != SQLITE_OK ||
      (rc = mem_exec_id(h, "delete from pending where id = ?1", rowid)) != SQLITE_OK ||
      (rc = mem_exec_id(h, "insert or ignore into deleted values (?1)", rowid)) != SQLITE_OK)
    return rc;
  sqlite3_str_appendf(add_op(h, "delete", t), ",\"id\":%lld}", rowid);
  h->deleted = 1;
  return SQLITE_OK;
}

static void reset(http_backend *h) {
  sqlite3_free(sqlite3_str_finish(h->ops));
  h->ops = NULL;
  h->nops = 0;
  h->written = 0;
  h->deleted = 0;
  sqlite3_exec(h->mem, "delete from pending; delete from deleted;", NULL, NULL, NULL);
}

static int http_begin(nr_backend *base) {
  http_backend *h = (http_backend *)base;
  reset(h);
  h->in_txn = 1;
  return SQLITE_OK;
}

/* On failure the pending writes stay put: SQLite follows up with a rollback. */
static int http_commit(nr_backend *base) {
  http_backend *h = (http_backend *)base;
  if (h->nops > 0) {
    char *ops = sqlite3_str_finish(h->ops);
    h->ops = NULL;
    char *body = sqlite3_mprintf("{\"ops\":[%s]}", ops ? ops : "");
    char *response = NULL;
    int rc = post(h, "/v1/commit", body, &response);
    sqlite3_free(response);
    if (rc != SQLITE_OK) {
      /* Keep the ops for a retried commit, as SQLite allows. */
      h->ops = sqlite3_str_new(NULL);
      sqlite3_str_appendall(h->ops, ops ? ops : "");
      sqlite3_free(ops);
      return rc;
    }
    sqlite3_free(ops);
  }
  reset(h);
  h->in_txn = 0;
  return SQLITE_OK;
}

static int http_rollback(nr_backend *base) {
  http_backend *h = (http_backend *)base;
  reset(h);
  h->in_txn = 0;
  return SQLITE_OK;
}

static void http_close(nr_backend *base) {
  http_backend *h = (http_backend *)base;
  if (h->curl)
    curl_easy_cleanup(h->curl);
  curl_slist_free_all(h->headers);
  sqlite3_finalize(h->quote);
  sqlite3_close(h->mem);
  sqlite3_free(sqlite3_str_finish(h->ops));
  sqlite3_free(h->url);
  sqlite3_free(h->base.err);
  sqlite3_free(h);
}

static const struct nr_backend_ops http_ops = {
  .close = http_close,
  .query = http_query,
  .rows_next = http_rows_next,
  .rows_column = http_rows_column,
  .rows_close = http_rows_close,
  .insert = http_insert,
  .update = http_update,
  .delete = http_delete,
  .begin = http_begin,
  .commit = http_commit,
  .rollback = http_rollback,
};

int nr_http_open(const char *uri, nr_backend **out, char **errmsg) {
  http_backend *h = sqlite3_malloc(sizeof *h);
  if (!h)
    return SQLITE_NOMEM;
  memset(h, 0, sizeof *h);
  h->base.ops = &http_ops;
  size_t n = strlen(uri);
  while (n > 0 && uri[n - 1] == '/')
    n--;
  h->url = sqlite3_mprintf("%.*s", (int)n, uri);

  int rc = sqlite3_open_v2(":memory:", &h->mem, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
  if (rc == SQLITE_OK)
    rc = sqlite3_exec(h->mem, mem_schema, NULL, NULL, NULL);
  if (rc == SQLITE_OK)
    rc = sqlite3_prepare_v2(h->mem, "select json_quote(?1)", -1, &h->quote, NULL);
  if (rc != SQLITE_OK) {
    *errmsg = sqlite3_mprintf("nixremote: %s", h->mem ? sqlite3_errmsg(h->mem) : sqlite3_errstr(rc));
    http_close(&h->base);
    return rc;
  }

  curl_global_init(CURL_GLOBAL_DEFAULT);
  h->curl = curl_easy_init();
  h->headers = curl_slist_append(NULL, "Content-Type: application/json");
  /* Send bodies straight away rather than waiting for 100 Continue. */
  h->headers = curl_slist_append(h->headers, "Expect:");
  if (!h->curl || !h->headers) {
    *errmsg = sqlite3_mprintf("nixremote: cannot initialize libcurl");
    http_close(&h->base);
    return SQLITE_ERROR;
  }
  curl_easy_setopt(h->curl, CURLOPT_HTTPHEADER, h->headers);
  curl_easy_setopt(h->curl, CURLOPT_WRITEFUNCTION, on_body);
  curl_easy_setopt(h->curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(h->curl, CURLOPT_CONNECTTIMEOUT, 10L);
  curl_easy_setopt(h->curl, CURLOPT_TIMEOUT, 300L);
  *out = &h->base;
  return SQLITE_OK;
}
