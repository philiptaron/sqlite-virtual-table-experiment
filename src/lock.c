/*
 * Whether this process has lost a lock it holds on a store path's lock
 * file: say, because its host was cut off from the NFS server for longer
 * than the lease, and another host has taken the lock since.
 *
 * Nix never looks at a lock file again once it holds the lock, so it
 * can't tell. Linux can: once its NFS client has marked a lock lost
 * (recover_lost_locks is off), reads and writes under it fail with EIO.
 * A lock file is empty, so only a read with O_DIRECT reaches the server
 * (see test/lockprobe.py). The read has to be on a descriptor Nix already
 * has, because closing any other descriptor for the file would drop the
 * process's locks on it.
 */
#define _GNU_SOURCE
#include "backend.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/vfs.h>
#include <unistd.h>

#define NFS_SUPER_MAGIC 0x6969

static int ends_with(const char *s, size_t n, const char *suffix) {
  size_t k = strlen(suffix);
  return n >= k && memcmp(s + n - k, suffix, k) == 0;
}

/* Whether a read of fd with O_DIRECT fails with EIO. The flag is on the
   open file description, which Nix shares, so put it back afterwards. */
static int direct_read_fails(int fd, void *buf, size_t size) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_DIRECT) != 0)
    return 0;
  int lost = pread(fd, buf, size, 0) < 0 && errno == EIO;
  fcntl(fd, F_SETFL, flags);
  return lost;
}

int nr_lock_lost(const char *path) {
  const char *base = path ? strrchr(path, '/') : NULL;
  if (!base)
    return 0;
  char suffix[NAME_MAX + 8];
  if (snprintf(suffix, sizeof suffix, "%s.lock", base) >= (int)sizeof suffix)
    return 0;

  DIR *fds = opendir("/proc/self/fd");
  if (!fds)
    return 0;
  enum { SIZE = 4096 };  /* O_DIRECT may need the buffer aligned */
  void *buf = NULL;
  int lost = 0;
  struct dirent *e;
  while (!lost && (e = readdir(fds))) {
    char link[64], target[PATH_MAX];
    snprintf(link, sizeof link, "/proc/self/fd/%s", e->d_name);
    ssize_t n = readlink(link, target, sizeof target);
    if (n <= 0 || n == (ssize_t)sizeof target)
      continue;
    if (ends_with(target, (size_t)n, " (deleted)"))
      n -= strlen(" (deleted)");
    if (!ends_with(target, (size_t)n, suffix))
      continue;
    int fd = atoi(e->d_name);
    struct statfs fs;
    if (fstatfs(fd, &fs) != 0 || fs.f_type != NFS_SUPER_MAGIC)
      continue;
    if (!buf && posix_memalign(&buf, SIZE, SIZE) != 0) {
      buf = NULL;
      break;
    }
    lost = direct_read_fails(fd, buf, SIZE);
  }
  closedir(fds);
  free(buf);
  return lost;
}

#else

int nr_lock_lost(const char *path) {
  (void)path;
  return 0;
}

#endif
