/*
 * The boundary between the virtual table module (vtab.c) and whatever
 * actually holds the store metadata:
 *
 *   backend_http.c    the metadata service (server/nixremote-server)
 *   backend_sqlite.c  another SQLite file, for tests and experiments
 *
 * nr_backend_open picks one by the URI's scheme.
 */
#ifndef NIXREMOTE_BACKEND_H
#define NIXREMOTE_BACKEND_H

#include <sqlite3ext.h>

/* The tables of Nix's store schema (src/libstore/schema.sql), and the one
   CA derivations add (ca-specific-schema.sql). */
struct nr_table {
  const char *name;
  const char *decl;        /* for sqlite3_declare_vtab */
  int ncols;
  const char *const *cols;
  int rowid_col;           /* integer key column, or -1 if rows have none */
  int path_keyed;          /* the key is nr_path_id() of column 1; if not, the backend numbers rows */
  unsigned indexed;        /* bitmask of columns the backend can look up by equality */
  unsigned unique;         /* ...of which these are unique */
  unsigned ordered;        /* ...and these can be scanned from a lower bound */
  int upsert;              /* Nix writes this table with "insert or replace" */
};

#define NR_NTABLES 4
extern const struct nr_table nr_valid_paths, nr_refs, nr_derivation_outputs, nr_build_trace;
extern const struct nr_table *const nr_tables[NR_NTABLES];

enum nr_op { NR_SCAN, NR_EQ, NR_GE };

typedef struct nr_backend nr_backend;
typedef struct nr_rows nr_rows;

struct nr_backend_ops {
  void (*close)(nr_backend *);
  int (*query)(nr_backend *, const struct nr_table *, enum nr_op, int col, sqlite3_value *arg,
               nr_rows **out);
  int (*rows_next)(nr_rows *);
  sqlite3_value *(*rows_column)(nr_rows *, int col);
  void (*rows_close)(nr_rows *);
  int (*insert)(nr_backend *, const struct nr_table *, sqlite3_value **cols, sqlite3_int64 *rowid);
  int (*update)(nr_backend *, const struct nr_table *, sqlite3_int64 rowid, sqlite3_value **cols);
  int (*delete)(nr_backend *, const struct nr_table *, sqlite3_int64 rowid);
  int (*begin)(nr_backend *);
  int (*commit)(nr_backend *);
  int (*rollback)(nr_backend *);
};

/* Every backend's state, and every result set, starts with one of these. */
struct nr_backend {
  const struct nr_backend_ops *ops;
  char *err;
};

struct nr_rows {
  nr_backend *backend;
};

int nr_backend_open(const char *uri, nr_backend **out, char **errmsg);
int nr_sqlite_open(const char *uri, nr_backend **out, char **errmsg);
int nr_http_open(const char *uri, nr_backend **out, char **errmsg);

/* Record a failure's message on b and return rc. */
int nr_fail(nr_backend *b, int rc, const char *fmt, ...);

static inline const char *nr_backend_errmsg(nr_backend *b) {
  return b->err ? b->err : "unknown error";
}

static inline void nr_backend_close(nr_backend *b) {
  if (b)
    b->ops->close(b);
}

/* Rows of t where cols[col] = arg (NR_EQ), cols[col] >= arg in column order
 * (NR_GE), or all rows (NR_SCAN, col and arg ignored). */
static inline int nr_query(nr_backend *b, const struct nr_table *t, enum nr_op op, int col,
                           sqlite3_value *arg, nr_rows **out) {
  return b->ops->query(b, t, op, col, arg, out);
}

/* SQLITE_ROW, SQLITE_DONE, or an error. */
static inline int nr_rows_next(nr_rows *rows) {
  return rows->backend->ops->rows_next(rows);
}

static inline sqlite3_value *nr_rows_column(nr_rows *rows, int col) {
  return rows->backend->ops->rows_column(rows, col);
}

static inline void nr_rows_close(nr_rows *rows) {
  if (rows)
    rows->backend->ops->rows_close(rows);
}

/* cols has t->ncols entries. For ValidPaths the backend ignores cols[0] and
 * assigns nr_path_id(path); *rowid receives the new row's key. BuildTraceV3
 * rows are numbered by the backend, and a backend that numbers them only
 * once the transaction commits makes one up for *rowid, which Nix never
 * reads. */
static inline int nr_insert(nr_backend *b, const struct nr_table *t, sqlite3_value **cols,
                            sqlite3_int64 *rowid) {
  return b->ops->insert(b, t, cols, rowid);
}

static inline int nr_update(nr_backend *b, const struct nr_table *t, sqlite3_int64 rowid,
                            sqlite3_value **cols) {
  return b->ops->update(b, t, rowid, cols);
}

/* Deleting a ValidPaths row cascades to the Refs and DerivationOutputs
 * rows that hang off it, and fails if another path still refers to it. */
static inline int nr_delete(nr_backend *b, const struct nr_table *t, sqlite3_int64 rowid) {
  return b->ops->delete(b, t, rowid);
}

static inline int nr_begin(nr_backend *b) { return b->ops->begin(b); }
static inline int nr_commit(nr_backend *b) { return b->ops->commit(b); }
static inline int nr_rollback(nr_backend *b) { return b->ops->rollback(b); }

/*
 * The ValidPaths id of a store path. The hash part of
 * /nix/store/<hash>-<name> is 32 characters of Nix's base32 and already
 * uniformly random, so folding its first 13 characters (65 bits) into 63
 * bits gives an id that every host computes without asking anyone.
 * Returns -1 if path doesn't look like a store path.
 */
sqlite3_int64 nr_path_id(const char *path);

/*
 * Whether this process held a lock on path's lock file (path + ".lock") on
 * NFS, and the NFS client has since found it lost, or the watchdog finds
 * the server silent for too long (src/lock.c). Always 0 off Linux.
 */
int nr_lock_lost(const char *path);

/*
 * Kill this process if it holds a lock on NFS and the server hasn't
 * answered for two thirds of lease_seconds, the server's lease
 * (src/lock.c). Once per process; 0 turns it off. Does nothing off Linux.
 */
void nr_watchdog_start(int lease_seconds);

#endif
