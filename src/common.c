/*
 * What the virtual table module and the backends share: the shape of
 * Nix's tables, how store paths map to ids, and picking a backend.
 */
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <stdarg.h>
#include <string.h>

#include "backend.h"

static const char *const valid_paths_cols[] = {
  "id", "path", "hash", "registrationTime", "deriver", "narSize", "ultimate", "sigs", "ca",
};
const struct nr_table nr_valid_paths = {
  .name = "ValidPaths",
  .decl = "CREATE TABLE x(id INTEGER, path TEXT, hash TEXT, registrationTime INTEGER,"
          " deriver TEXT, narSize INTEGER, ultimate INTEGER, sigs TEXT, ca TEXT)",
  .ncols = 9,
  .cols = valid_paths_cols,
  .rowid_col = 0,
  .path_keyed = 1,
  .indexed = 1u << 0 | 1u << 1,
  .unique = 1u << 0 | 1u << 1,
  .ordered = 1u << 1,
};

static const char *const refs_cols[] = { "referrer", "reference" };
const struct nr_table nr_refs = {
  .name = "Refs",
  .decl = "CREATE TABLE x(referrer INTEGER, reference INTEGER)",
  .ncols = 2,
  .cols = refs_cols,
  .rowid_col = -1,
  .indexed = 1u << 0 | 1u << 1,
  .upsert = 1,
};

static const char *const derivation_outputs_cols[] = { "drv", "id", "path" };
const struct nr_table nr_derivation_outputs = {
  .name = "DerivationOutputs",
  .decl = "CREATE TABLE x(drv INTEGER, id TEXT, path TEXT)",
  .ncols = 3,
  .cols = derivation_outputs_cols,
  .rowid_col = -1,
  .indexed = 1u << 0 | 1u << 2,
  .upsert = 1,
};

/* What each CA derivation output was built as. Nix looks a row up by
   drvPath and outputName, and only ever changes its signatures. */
static const char *const build_trace_cols[] = { "id", "drvPath", "outputName", "outputPath", "signatures" };
const struct nr_table nr_build_trace = {
  .name = "BuildTraceV3",
  .decl = "CREATE TABLE x(id INTEGER, drvPath TEXT, outputName TEXT, outputPath TEXT, signatures TEXT)",
  .ncols = 5,
  .cols = build_trace_cols,
  .rowid_col = 0,
  .indexed = 1u << 0 | 1u << 1,
  .unique = 1u << 0,
};

const struct nr_table *const nr_tables[NR_NTABLES] = {
  &nr_valid_paths, &nr_refs, &nr_derivation_outputs, &nr_build_trace,
};

static const char nix_base32[] = "0123456789abcdfghijklmnpqrsvwxyz";

sqlite3_int64 nr_path_id(const char *path) {
  if (!path)
    return -1;
  const char *base = strrchr(path, '/');
  base = base ? base + 1 : path;
  if (strlen(base) < 33 || base[32] != '-')
    return -1;
  sqlite3_uint64 id = 0;
  for (int i = 0; i < 32; i++) {
    const char *digit = base[i] ? strchr(nix_base32, base[i]) : NULL;
    if (!digit)
      return -1;
    if (i < 13)
      id = id << 5 | (sqlite3_uint64)(digit - nix_base32);
  }
  return (sqlite3_int64)(id & 0x7fffffffffffffffULL);
}

int nr_fail(nr_backend *b, int rc, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  sqlite3_free(b->err);
  b->err = sqlite3_vmprintf(fmt, ap);
  va_end(ap);
  return rc;
}

int nr_backend_open(const char *uri, nr_backend **out, char **errmsg) {
  if (strncmp(uri, "http://", 7) == 0 || strncmp(uri, "https://", 8) == 0)
    return nr_http_open(uri, out, errmsg);
  if (strncmp(uri, "file:", 5) == 0)
    return nr_sqlite_open(uri, out, errmsg);
  *errmsg = sqlite3_mprintf("nixremote: backend \"%s\" is neither http(s): nor file:", uri);
  return SQLITE_ERROR;
}
