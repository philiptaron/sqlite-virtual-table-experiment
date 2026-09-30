/*
 * The "nixremote" virtual table module. A db.sqlite whose ValidPaths,
 * Refs, and DerivationOutputs are declared as
 *
 *   CREATE VIRTUAL TABLE ValidPaths USING nixremote(backend='file:/...')
 *
 * holds no store metadata of its own: every read and write Nix makes goes
 * to the backend (backend.h), which all hosts sharing the store talk to.
 */
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

#include <ctype.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "backend.h"

/*
 * One backend connection per (front database connection, backend URI),
 * shared by the three virtual tables so that they see one transaction.
 * Stored as client data on the front connection, which closes it.
 */
typedef struct {
  nr_backend *backend;
  int open;       /* a backend transaction is in progress */
} nr_conn;

typedef struct {
  sqlite3_vtab base;
  const struct nr_table *table;
  nr_conn *conn;
  int allow_delete;
} nr_vtab;

typedef struct {
  sqlite3_vtab_cursor base;
  nr_rows *rows;
  int eof;
  sqlite3_int64 rowid;   /* position in the result, for tables without a key */
} nr_cursor;

static void conn_free(void *p) {
  nr_conn *conn = p;
  nr_backend_close(conn->backend);
  sqlite3_free(conn);
}

static int fail(nr_vtab *vt, int rc, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  sqlite3_free(vt->base.zErrMsg);
  vt->base.zErrMsg = sqlite3_vmprintf(fmt, ap);
  va_end(ap);
  return rc;
}

static int backend_fail(nr_vtab *vt, int rc) {
  return fail(vt, rc, "nixremote: %s", nr_backend_errmsg(vt->conn->backend));
}

/*
 * Refuse to say that path is invalid, or to register it, once this process
 * has lost its lock on the path. Nix asks whether an output is valid right
 * before it deletes whatever is at the output path and moves its own build
 * there, and a host that lost the lock may be about to delete another
 * host's files that way. SQLITE_IOERR isn't one Nix retries.
 *
 * The process may have moved its output in already: say, its host froze
 * between an earlier check and the move, and Nix asks again after moving.
 * The plugin can't tell which, so it reports the path to the service as
 * suspect either way, for someone to verify.
 */
static int fence(nr_vtab *vt, const char *path) {
  if (!nr_lock_lost(path))
    return SQLITE_OK;
  int reported = nr_suspect(vt->conn->backend, path) == SQLITE_OK;
  return fail(vt, SQLITE_IOERR,
              "nixremote: this process lost its lock on %s.lock, so another host may be "
              "building or adding %s; refusing to act on it%s", path, path,
              reported ? ", and reporting it as suspect" : "");
}

/* Split a module argument like  backend='file:/x'  into key and unquoted value. */
static int parse_arg(const char *arg, char **key, char **value) {
  const char *eq = strchr(arg, '=');
  if (!eq)
    return 0;
  const char *k = arg, *ke = eq, *v = eq + 1, *ve = arg + strlen(arg);
  while (k < ke && isspace((unsigned char)*k)) k++;
  while (ke > k && isspace((unsigned char)ke[-1])) ke--;
  while (v < ve && isspace((unsigned char)*v)) v++;
  while (ve > v && isspace((unsigned char)ve[-1])) ve--;
  if (ve - v >= 2 && (*v == '\'' || *v == '"') && ve[-1] == *v) {
    v++;
    ve--;
  }
  *key = sqlite3_mprintf("%.*s", (int)(ke - k), k);
  *value = sqlite3_mprintf("%.*s", (int)(ve - v), v);
  return 1;
}

static int is_seconds(const char *s) {
  size_t n = strspn(s, "0123456789");
  return n > 0 && n < 7 && s[n] == '\0';
}

static int xConnect(sqlite3 *db, void *aux, int argc, const char *const *argv,
                    sqlite3_vtab **out, char **err) {
  (void)aux;
  const struct nr_table *table = NULL;
  for (int i = 0; i < NR_NTABLES; i++)
    if (sqlite3_stricmp(argv[2], nr_tables[i]->name) == 0)
      table = nr_tables[i];
  if (!table) {
    *err = sqlite3_mprintf("nixremote: no such Nix store table \"%s\"", argv[2]);
    return SQLITE_ERROR;
  }

  char *uri = NULL;
  /* The NFS server's lease in seconds, for the watchdog; nfsd's default. */
  int allow_delete = 0, lease = 90, rc = SQLITE_OK;
  for (int i = 3; i < argc && rc == SQLITE_OK; i++) {
    char *key, *value;
    if (!parse_arg(argv[i], &key, &value)) {
      *err = sqlite3_mprintf("nixremote: expected key=value, got \"%s\"", argv[i]);
      rc = SQLITE_ERROR;
      continue;
    }
    if (strcmp(key, "backend") == 0) {
      sqlite3_free(uri);
      uri = value;
      value = NULL;
    } else if (strcmp(key, "deletes") == 0 && strcmp(value, "allow") == 0) {
      allow_delete = 1;
    } else if (strcmp(key, "deletes") == 0 && strcmp(value, "deny") == 0) {
      allow_delete = 0;
    } else if (strcmp(key, "lease") == 0 && is_seconds(value)) {
      lease = atoi(value);
    } else {
      *err = sqlite3_mprintf("nixremote: unknown argument \"%s\"", argv[i]);
      rc = SQLITE_ERROR;
    }
    sqlite3_free(key);
    sqlite3_free(value);
  }
  if (rc == SQLITE_OK && !uri) {
    *err = sqlite3_mprintf("nixremote: missing backend='...' argument");
    rc = SQLITE_ERROR;
  }

  char *key = uri ? sqlite3_mprintf("nixremote:%s", uri) : NULL;
  nr_conn *conn = key ? sqlite3_get_clientdata(db, key) : NULL;
  if (rc == SQLITE_OK && !conn) {
    conn = sqlite3_malloc(sizeof *conn);
    if (!conn) {
      rc = SQLITE_NOMEM;
    } else {
      memset(conn, 0, sizeof *conn);
      rc = nr_backend_open(uri, &conn->backend, err);
      if (rc == SQLITE_OK)
        rc = sqlite3_set_clientdata(db, key, conn, conn_free);
      else
        sqlite3_free(conn);
    }
  }
  if (rc == SQLITE_OK)
    rc = sqlite3_declare_vtab(db, table->decl);
  /* Before Nix takes any lock in the store. */
  if (rc == SQLITE_OK)
    nr_watchdog_start(lease);

  nr_vtab *vt = NULL;
  if (rc == SQLITE_OK && !(vt = sqlite3_malloc(sizeof *vt)))
    rc = SQLITE_NOMEM;
  if (rc == SQLITE_OK) {
    memset(vt, 0, sizeof *vt);
    vt->table = table;
    vt->conn = conn;
    vt->allow_delete = allow_delete;
    *out = &vt->base;
  }
  sqlite3_free(key);
  sqlite3_free(uri);
  return rc;
}

static int xDisconnect(sqlite3_vtab *p) {
  sqlite3_free(p);
  return SQLITE_OK;
}

/*
 * Nix's statements only ever filter on one indexed column, so a plan is a
 * single (column, operator) pair; everything else SQLite filters itself.
 * idxNum packs it as col << 2 | op.
 */
static int xBestIndex(sqlite3_vtab *p, sqlite3_index_info *info) {
  const struct nr_table *t = ((nr_vtab *)p)->table;
  int best = -1, best_col = 0;
  enum nr_op best_op = NR_SCAN;
  double best_cost = 1e6;

  for (int i = 0; i < info->nConstraint; i++) {
    const struct sqlite3_index_constraint *c = &info->aConstraint[i];
    int col = c->iColumn < 0 ? t->rowid_col : c->iColumn;
    if (!c->usable || col < 0)
      continue;
    enum nr_op op;
    double cost;
    if (c->op == SQLITE_INDEX_CONSTRAINT_EQ && t->indexed & 1u << col) {
      op = NR_EQ;
      cost = t->unique & 1u << col ? 1 : 10;
    } else if (c->op == SQLITE_INDEX_CONSTRAINT_GE && t->ordered & 1u << col) {
      op = NR_GE;
      cost = 1000;
    } else {
      continue;
    }
    if (cost < best_cost) {
      best = i;
      best_col = col;
      best_op = op;
      best_cost = cost;
    }
  }

  info->estimatedCost = best_cost;
  info->estimatedRows = (sqlite3_int64)best_cost;
  info->idxNum = best_col << 2 | best_op;
  if (best >= 0) {
    info->aConstraintUsage[best].argvIndex = 1;
    info->aConstraintUsage[best].omit = best_op == NR_EQ;
    if (best_op == NR_EQ && t->unique & 1u << best_col)
      info->idxFlags |= SQLITE_INDEX_SCAN_UNIQUE;
  }
  return SQLITE_OK;
}

static int xOpen(sqlite3_vtab *p, sqlite3_vtab_cursor **out) {
  (void)p;
  nr_cursor *cur = sqlite3_malloc(sizeof *cur);
  if (!cur)
    return SQLITE_NOMEM;
  memset(cur, 0, sizeof *cur);
  *out = &cur->base;
  return SQLITE_OK;
}

static int xClose(sqlite3_vtab_cursor *c) {
  nr_cursor *cur = (nr_cursor *)c;
  nr_rows_close(cur->rows);
  sqlite3_free(cur);
  return SQLITE_OK;
}

static int xNext(sqlite3_vtab_cursor *c) {
  nr_cursor *cur = (nr_cursor *)c;
  int rc = nr_rows_next(cur->rows);
  if (rc == SQLITE_ROW) {
    cur->rowid++;
    return SQLITE_OK;
  }
  cur->eof = 1;
  return rc == SQLITE_DONE ? SQLITE_OK : backend_fail((nr_vtab *)c->pVtab, rc);
}

static int xFilter(sqlite3_vtab_cursor *c, int idxNum, const char *idxStr, int argc,
                   sqlite3_value **argv) {
  (void)idxStr;
  nr_cursor *cur = (nr_cursor *)c;
  nr_vtab *vt = (nr_vtab *)c->pVtab;
  nr_rows_close(cur->rows);
  cur->rows = NULL;
  cur->eof = 0;
  cur->rowid = 0;
  int rc = nr_query(vt->conn->backend, vt->table, idxNum & 3, idxNum >> 2,
                    argc > 0 ? argv[0] : NULL, &cur->rows);
  if (rc != SQLITE_OK) {
    cur->eof = 1;
    return backend_fail(vt, rc);
  }
  rc = xNext(c);
  if (rc == SQLITE_OK && cur->eof && vt->table == &nr_valid_paths && (idxNum & 3) == NR_EQ &&
      idxNum >> 2 == 1)
    rc = fence(vt, (const char *)sqlite3_value_text(argv[0]));
  return rc;
}

static int xEof(sqlite3_vtab_cursor *c) {
  return ((nr_cursor *)c)->eof;
}

static int xColumn(sqlite3_vtab_cursor *c, sqlite3_context *ctx, int col) {
  sqlite3_result_value(ctx, nr_rows_column(((nr_cursor *)c)->rows, col));
  return SQLITE_OK;
}

static int xRowid(sqlite3_vtab_cursor *c, sqlite3_int64 *rowid) {
  nr_cursor *cur = (nr_cursor *)c;
  int key = ((nr_vtab *)c->pVtab)->table->rowid_col;
  *rowid = key >= 0 ? sqlite3_value_int64(nr_rows_column(cur->rows, key)) : cur->rowid;
  return SQLITE_OK;
}

static int xUpdate(sqlite3_vtab *p, int argc, sqlite3_value **argv, sqlite3_int64 *rowid) {
  nr_vtab *vt = (nr_vtab *)p;
  const struct nr_table *t = vt->table;
  nr_backend *b = vt->conn->backend;
  int rc;

  if (argc == 1) {
    if (t->rowid_col < 0)
      return fail(vt, SQLITE_CONSTRAINT, "nixremote: %s rows are only deleted along with their ValidPaths row", t->name);
    if (!vt->allow_delete)
      return fail(vt, SQLITE_AUTH, "nixremote: deleting store paths is disabled on this host (deletes=deny); garbage collection of a shared store must be coordinated centrally");
    rc = nr_delete(b, t, sqlite3_value_int64(argv[0]));
  } else if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
    if (t->rowid_col >= 0 && (sqlite3_value_type(argv[1]) != SQLITE_NULL ||
                              sqlite3_value_type(argv[2 + t->rowid_col]) != SQLITE_NULL))
      return fail(vt, SQLITE_CONSTRAINT, "nixremote: %s ids are nixremote's to assign and cannot be given", t->name);
    if (t == &nr_valid_paths && (rc = fence(vt, (const char *)sqlite3_value_text(argv[3]))) != SQLITE_OK)
      return rc;
    rc = nr_insert(b, t, argv + 2, rowid);
    /* Another host registered the path, or the derivation output, between
       Nix's check and this insert. Nix retries on SQLITE_BUSY, and on the
       retry it will see the row and update it instead. */
    if (rc == SQLITE_CONSTRAINT_UNIQUE && t->rowid_col >= 0)
      return fail(vt, SQLITE_BUSY, "nixremote: %s was registered concurrently; retrying",
                  sqlite3_value_text(argv[3]));
  } else {
    if (t->rowid_col < 0)
      return fail(vt, SQLITE_CONSTRAINT, "nixremote: %s rows cannot be updated", t->name);
    if (sqlite3_value_int64(argv[0]) != sqlite3_value_int64(argv[1]) ||
        (t->path_keyed &&
         sqlite3_value_int64(argv[0]) != nr_path_id((const char *)sqlite3_value_text(argv[3]))))
      return fail(vt, SQLITE_CONSTRAINT, "nixremote: a %s row's id and key cannot change", t->name);
    if (t == &nr_valid_paths && (rc = fence(vt, (const char *)sqlite3_value_text(argv[3]))) != SQLITE_OK)
      return rc;
    rc = nr_update(b, t, sqlite3_value_int64(argv[0]), argv + 2);
  }
  return rc == SQLITE_OK ? SQLITE_OK : backend_fail(vt, rc);
}

/*
 * SQLite calls xBegin/xSync/xCommit/xRollback per table, but the tables
 * share one backend transaction, and a table can join a transaction
 * without xBegin (CREATE VIRTUAL TABLE does that). So track whether the
 * backend transaction is open rather than counting calls. It commits in
 * the first xSync: the last point at which a failure (say, a conflict
 * another host caused) can still abort the transaction, since xCommit is
 * not allowed to fail.
 */
static int xBegin(sqlite3_vtab *p) {
  nr_vtab *vt = (nr_vtab *)p;
  if (vt->conn->open)
    return SQLITE_OK;
  int rc = nr_begin(vt->conn->backend);
  if (rc != SQLITE_OK)
    return backend_fail(vt, rc);
  vt->conn->open = 1;
  return SQLITE_OK;
}

static int xSync(sqlite3_vtab *p) {
  nr_vtab *vt = (nr_vtab *)p;
  if (!vt->conn->open)
    return SQLITE_OK;
  int rc = nr_commit(vt->conn->backend);
  if (rc != SQLITE_OK)
    return backend_fail(vt, rc);
  vt->conn->open = 0;
  return SQLITE_OK;
}

static int xCommit(sqlite3_vtab *p) {
  return xSync(p);
}

static int xRollback(sqlite3_vtab *p) {
  nr_conn *conn = ((nr_vtab *)p)->conn;
  /* After xSync has committed there is nothing to undo; that only happens
     if committing the (otherwise empty) front database itself fails. */
  if (conn->open) {
    nr_rollback(conn->backend);
    conn->open = 0;
  }
  return SQLITE_OK;
}

static sqlite3_module module = {
  .iVersion = 0,
  .xCreate = xConnect,
  .xConnect = xConnect,
  .xBestIndex = xBestIndex,
  .xDisconnect = xDisconnect,
  .xDestroy = xDisconnect,  /* dropping the local declaration leaves the backend alone */
  .xOpen = xOpen,
  .xClose = xClose,
  .xFilter = xFilter,
  .xNext = xNext,
  .xEof = xEof,
  .xColumn = xColumn,
  .xRowid = xRowid,
  .xUpdate = xUpdate,
  .xBegin = xBegin,
  .xSync = xSync,
  .xCommit = xCommit,
  .xRollback = xRollback,
};

#ifdef _WIN32
__declspec(dllexport)
#endif
int sqlite3_nixremote_init(sqlite3 *db, char **err, const sqlite3_api_routines *api) {
  SQLITE_EXTENSION_INIT2(api);
  if (sqlite3_libversion_number() < 3044000) {
    *err = sqlite3_mprintf("nixremote: needs SQLite 3.44 or newer, have %s", sqlite3_libversion());
    return SQLITE_ERROR;
  }
  return sqlite3_create_module(db, "nixremote", &module, NULL);
}
