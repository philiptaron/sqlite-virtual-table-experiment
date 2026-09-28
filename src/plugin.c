/*
 * Nix plugin entry point (plugin-files = .../libnixremote.so). Registers
 * the nixremote module on every SQLite connection Nix opens from now on,
 * including the one to the store's db.sqlite.
 *
 * sqlite3_auto_extension is looked up in the already-loaded libsqlite3
 * rather than linked: linking our own copy would register the module in a
 * SQLite instance that Nix never uses.
 */
#include <dlfcn.h>
#include <stdio.h>

typedef int auto_extension_fn(void (*)(void));

int sqlite3_nixremote_init();

void nix_plugin_entry(void) {
  auto_extension_fn *auto_extension = (auto_extension_fn *)dlsym(RTLD_DEFAULT, "sqlite3_auto_extension");
  if (!auto_extension) {
    fprintf(stderr, "nixremote: sqlite3_auto_extension not found in this process: %s\n", dlerror());
    return;
  }
  if (auto_extension((void (*)(void))sqlite3_nixremote_init) != 0)
    fprintf(stderr, "nixremote: sqlite3_auto_extension failed\n");
}
