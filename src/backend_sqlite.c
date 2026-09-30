/*
 * A backend that keeps the store metadata in another SQLite database
 * (backend='file:...'), for tests and experiments without the service.
 * Its schema is Nix's own, except that ValidPaths ids come from
 * nr_path_id() instead of autoincrement, so foreign keys and the
 * DeleteSelfRefs trigger give the same cascade/restrict behaviour Nix
 * relies on.
 */
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <string.h>

#include "backend.h"

typedef struct {
  nr_backend base;
  sqlite3 *db;
} sqlite_backend;

typedef struct {
  nr_rows base;
  sqlite3_stmt *stmt;
} sqlite_rows;

static const char schema[] =
  "create table if not exists ValidPaths ("
  "  id integer primary key not null,"
  "  path text unique not null,"
  "  hash text not null,"
  "  registrationTime integer not null,"
  "  deriver text,"
  "  narSize integer,"
  "  ultimate integer,"
  "  sigs text,"
  "  ca text"
  ");"
  "create table if not exists Refs ("
  "  referrer integer not null,"
  "  reference integer not null,"
  "  primary key (referrer, reference),"
  "  foreign key (referrer) references ValidPaths(id) on delete cascade,"
  "  foreign key (reference) references ValidPaths(id) on delete restrict"
  ");"
  "create index if not exists IndexReference on Refs(reference);"
  "create trigger if not exists DeleteSelfRefs before delete on ValidPaths"
  "  begin delete from Refs where referrer = old.id and reference = old.id; end;"
  "create table if not exists DerivationOutputs ("
  "  drv integer not null,"
  "  id text not null,"
  "  path text not null,"
  "  primary key (drv, id),"
  "  foreign key (drv) references ValidPaths(id) on delete cascade"
  ");"
  "create index if not exists IndexDerivationOutputs on DerivationOutputs(path);"
  /* Nix's has only an index on (drvPath, outputName), but a second row for
     one derivation output is what two hosts racing to register it make. */
  "create table if not exists BuildTraceV3 ("
  "  id integer primary key autoincrement not null,"
  "  drvPath text not null,"
  "  outputName text not null,"
  "  outputPath text not null,"
  "  signatures text,"
  "  unique (drvPath, outputName)"
  ");";

static int set_err(sqlite_backend *b, int rc) {
  return nr_fail(&b->base, rc, "%s", sqlite3_errmsg(b->db));
}

static int exec(sqlite_backend *b, const char *sql) {
  int rc = sqlite3_exec(b->db, sql, NULL, NULL, NULL);
  return rc == SQLITE_OK ? rc : set_err(b, rc);
}

static const struct nr_backend_ops sqlite_ops;

int nr_sqlite_open(const char *uri, nr_backend **out, char **errmsg) {
  sqlite_backend *b = sqlite3_malloc(sizeof *b);
  if (!b)
    return SQLITE_NOMEM;
  memset(b, 0, sizeof *b);
  b->base.ops = &sqlite_ops;
  int rc = sqlite3_open_v2(uri, &b->db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL);
  if (rc == SQLITE_OK) {
    sqlite3_extended_result_codes(b->db, 1);
    sqlite3_busy_timeout(b->db, 60 * 1000);
    rc = sqlite3_exec(b->db, "pragma journal_mode = wal; pragma foreign_keys = 1;", NULL, NULL, NULL);
  }
  if (rc == SQLITE_OK)
    rc = sqlite3_exec(b->db, schema, NULL, NULL, NULL);
  if (rc != SQLITE_OK) {
    *errmsg = sqlite3_mprintf("nixremote: opening backend %s: %s", uri,
                              b->db ? sqlite3_errmsg(b->db) : sqlite3_errstr(rc));
    nr_backend_close(&b->base);
    return rc;
  }
  *out = &b->base;
  return SQLITE_OK;
}

static void sqlite_close(nr_backend *base) {
  sqlite_backend *b = (sqlite_backend *)base;
  sqlite3_close(b->db);
  sqlite3_free(b->base.err);
  sqlite3_free(b);
}

static void append_cols(sqlite3_str *s, const struct nr_table *t, int skip, const char *suffix) {
  const char *sep = "";
  for (int i = 0; i < t->ncols; i++) {
    if (i == skip)
      continue;
    sqlite3_str_appendf(s, "%s%s%s", sep, t->cols[i], suffix);
    sep = ", ";
  }
}

static int prepare(sqlite_backend *b, sqlite3_str *s, sqlite3_stmt **stmt) {
  char *sql = sqlite3_str_finish(s);
  if (!sql)
    return SQLITE_NOMEM;
  int rc = sqlite3_prepare_v2(b->db, sql, -1, stmt, NULL);
  sqlite3_free(sql);
  return rc == SQLITE_OK ? rc : set_err(b, rc);
}

/* Step a write statement to completion and finalize it. */
static int run(sqlite_backend *b, sqlite3_stmt *stmt) {
  int rc = sqlite3_step(stmt);
  if (rc == SQLITE_DONE)
    rc = SQLITE_OK;
  else
    set_err(b, rc);
  sqlite3_finalize(stmt);
  return rc;
}

static int sqlite_query(nr_backend *base, const struct nr_table *t, enum nr_op op, int col,
                        sqlite3_value *arg, nr_rows **out) {
  sqlite_backend *b = (sqlite_backend *)base;
  sqlite3_str *s = sqlite3_str_new(b->db);
  sqlite3_str_appendall(s, "select ");
  append_cols(s, t, -1, "");
  sqlite3_str_appendf(s, " from %s", t->name);
  if (op == NR_EQ)
    sqlite3_str_appendf(s, " where %s = ?1", t->cols[col]);
  else if (op == NR_GE)
    sqlite3_str_appendf(s, " where %s >= ?1 order by %s", t->cols[col], t->cols[col]);

  sqlite3_stmt *stmt;
  int rc = prepare(b, s, &stmt);
  if (rc != SQLITE_OK)
    return rc;
  if (op != NR_SCAN)
    sqlite3_bind_value(stmt, 1, arg);
  sqlite_rows *rows = sqlite3_malloc(sizeof *rows);
  if (!rows) {
    sqlite3_finalize(stmt);
    return SQLITE_NOMEM;
  }
  rows->base.backend = base;
  rows->stmt = stmt;
  *out = &rows->base;
  return SQLITE_OK;
}

static int sqlite_rows_next(nr_rows *base) {
  sqlite_rows *rows = (sqlite_rows *)base;
  int rc = sqlite3_step(rows->stmt);
  return rc == SQLITE_ROW || rc == SQLITE_DONE ? rc : set_err((sqlite_backend *)base->backend, rc);
}

static sqlite3_value *sqlite_rows_column(nr_rows *base, int col) {
  return sqlite3_column_value(((sqlite_rows *)base)->stmt, col);
}

static void sqlite_rows_close(nr_rows *base) {
  sqlite3_finalize(((sqlite_rows *)base)->stmt);
  sqlite3_free(base);
}

/*
 * A ValidPaths insert failed on the id. Since the id is derived from the
 * path, that is almost always the same path already being registered
 * (reported as SQLITE_CONSTRAINT_UNIQUE, which the caller may retry), and
 * only otherwise a genuine collision between two paths' ids.
 */
static int explain_id_conflict(sqlite_backend *b, sqlite3_int64 id, const char *path) {
  sqlite3_stmt *stmt;
  int same = 0;
  if (sqlite3_prepare_v2(b->db, "select path = ?2 from ValidPaths where id = ?1", -1, &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(stmt, 1, id);
    sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT);
    same = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
  }
  if (same)
    return nr_fail(&b->base, SQLITE_CONSTRAINT_UNIQUE, "%s is already registered", path);
  return nr_fail(&b->base, SQLITE_CONSTRAINT_PRIMARYKEY, "id %lld of %s collides with another store path",
                 id, path);
}

static int sqlite_insert(nr_backend *base, const struct nr_table *t, sqlite3_value **cols,
                         sqlite3_int64 *rowid) {
  sqlite_backend *b = (sqlite_backend *)base;
  sqlite3_int64 id = 0;
  if (t->path_keyed) {
    id = nr_path_id((const char *)sqlite3_value_text(cols[1]));
    if (id < 0)
      return nr_fail(base, SQLITE_CONSTRAINT, "\"%s\" is not a store path", sqlite3_value_text(cols[1]));
  }

  sqlite3_str *s = sqlite3_str_new(b->db);
  sqlite3_str_appendf(s, "insert%s into %s (", t->upsert ? " or replace" : "", t->name);
  append_cols(s, t, -1, "");
  sqlite3_str_appendall(s, ") values (");
  for (int i = 0; i < t->ncols; i++)
    sqlite3_str_appendf(s, "%s?%d", i ? ", " : "", i + 1);
  sqlite3_str_appendall(s, ")");

  sqlite3_stmt *stmt;
  int rc = prepare(b, s, &stmt);
  if (rc != SQLITE_OK)
    return rc;
  for (int i = 0; i < t->ncols; i++) {
    if (i == t->rowid_col && t->path_keyed)
      sqlite3_bind_int64(stmt, i + 1, id);
    else if (i == t->rowid_col)
      sqlite3_bind_null(stmt, i + 1);
    else
      sqlite3_bind_value(stmt, i + 1, cols[i]);
  }
  rc = run(b, stmt);
  if (rc == SQLITE_OK)
    *rowid = t->path_keyed ? id : sqlite3_last_insert_rowid(b->db);
  if (rc == SQLITE_CONSTRAINT_PRIMARYKEY && t->path_keyed)
    rc = explain_id_conflict(b, id, (const char *)sqlite3_value_text(cols[1]));
  return rc;
}

static int sqlite_update(nr_backend *base, const struct nr_table *t, sqlite3_int64 rowid,
                         sqlite3_value **cols) {
  sqlite_backend *b = (sqlite_backend *)base;
  sqlite3_str *s = sqlite3_str_new(b->db);
  sqlite3_str_appendf(s, "update %s set ", t->name);
  append_cols(s, t, t->rowid_col, " = ?");
  sqlite3_str_appendf(s, " where %s = ?", t->cols[t->rowid_col]);

  sqlite3_stmt *stmt;
  int rc = prepare(b, s, &stmt);
  if (rc != SQLITE_OK)
    return rc;
  int n = 1;
  for (int i = 0; i < t->ncols; i++)
    if (i != t->rowid_col)
      sqlite3_bind_value(stmt, n++, cols[i]);
  sqlite3_bind_int64(stmt, n, rowid);
  return run(b, stmt);
}

static int sqlite_delete(nr_backend *base, const struct nr_table *t, sqlite3_int64 rowid) {
  sqlite_backend *b = (sqlite_backend *)base;
  sqlite3_str *s = sqlite3_str_new(b->db);
  sqlite3_str_appendf(s, "delete from %s where %s = ?1", t->name, t->cols[t->rowid_col]);
  sqlite3_stmt *stmt;
  int rc = prepare(b, s, &stmt);
  if (rc != SQLITE_OK)
    return rc;
  sqlite3_bind_int64(stmt, 1, rowid);
  return run(b, stmt);
}

static int sqlite_begin(nr_backend *b) {
  return exec((sqlite_backend *)b, "begin immediate");
}

static int sqlite_commit(nr_backend *b) {
  return exec((sqlite_backend *)b, "commit");
}

static int sqlite_rollback(nr_backend *b) {
  return exec((sqlite_backend *)b, "rollback");
}

static const struct nr_backend_ops sqlite_ops = {
  .close = sqlite_close,
  .query = sqlite_query,
  .rows_next = sqlite_rows_next,
  .rows_column = sqlite_rows_column,
  .rows_close = sqlite_rows_close,
  .insert = sqlite_insert,
  .update = sqlite_update,
  .delete = sqlite_delete,
  .begin = sqlite_begin,
  .commit = sqlite_commit,
  .rollback = sqlite_rollback,
};
