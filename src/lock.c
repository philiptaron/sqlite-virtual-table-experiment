/*
 * Keeping a process from acting on a store path after another host may have
 * taken its lock: say, because this host was cut off from the NFS server
 * for longer than the server's lease, and the server gave the lock to the
 * next host that asked.
 *
 * Nix never looks at a lock file again once it holds the lock, so it can't
 * tell. Two things here can:
 *
 * - The watchdog (nr_watchdog_start). A lock on NFS lasts as long as the
 *   host's lease with the server, and each request to the server renews
 *   the lease, from the moment it was sent until at least a lease later.
 *   So a thread in each process asks the server something every few
 *   seconds while the process holds a lock there, and another thread
 *   kills the process once none of those requests has been answered for
 *   two thirds of the lease. The process is then gone before the server
 *   can give its locks away, much as if the host had crashed, and it
 *   can't carry on once the network comes back.
 *
 * - The check (nr_lock_lost), for when the watchdog couldn't run: a
 *   process or host that was frozen, or a lease set wrongly. Once Linux's
 *   NFS client has marked a lock lost (recover_lost_locks is off), reads
 *   and writes under it fail with EIO. A lock file is empty, so only a
 *   read with O_DIRECT reaches the server (see test/lockprobe.py). The
 *   read has to be on a descriptor Nix already has, because closing any
 *   other descriptor for the file would drop the process's locks on it.
 */
#define _GNU_SOURCE
#include "backend.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>

#define NFS_SUPER_MAGIC 0x6969

static int ends_with(const char *s, size_t n, const char *suffix) {
  size_t k = strlen(suffix);
  return n >= k && memcmp(s + n - k, suffix, k) == 0;
}

/* Whether a read of fd with O_DIRECT fails as it does once the lock is
   lost: EIO, or ESTALE if the lock file has been deleted since. The flag
   is on the open file description, which Nix shares, so put it back. */
static int direct_read_fails(int fd, void *buf, size_t size) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_DIRECT) != 0)
    return 0;
  int lost = pread(fd, buf, size, 0) < 0 && (errno == EIO || errno == ESTALE);
  fcntl(fd, F_SETFL, flags);
  return lost;
}

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* The watchdog's state. last_contact is when the last round of requests
   that were all answered was sent, or when the process last held no lock
   on NFS. */
static pid_t watchdog_pid;
static long long deadline_ms;
static _Atomic long long last_contact;

enum { MAX_MOUNTS = 64, MAX_HELD = 256 };

/* The ids of the NFS mounts this process sees. Reading mountinfo, like
   everything the killing thread does, never waits on the network. */
static int nfs_mounts(int *ids) {
  FILE *f = fopen("/proc/self/mountinfo", "re");
  if (!f)
    return 0;
  int n = 0;
  char line[4096];
  while (n < MAX_MOUNTS && fgets(line, sizeof line, f)) {
    int id;
    char fstype[32];
    const char *sep = strstr(line, " - ");
    if (sep && sscanf(line, "%d", &id) == 1 && sscanf(sep + 3, "%31s", fstype) == 1 &&
        strncmp(fstype, "nfs", 3) == 0)
      ids[n++] = id;
  }
  fclose(f);
  return n;
}

/* The descriptors on which this process holds a lock on an NFS mount, from
   /proc/self/fdinfo, which lists a descriptor's locks only while they're
   held, and not while they're waited for. */
static int held_nfs_locks(int *fds) {
  int mounts[MAX_MOUNTS];
  int nmounts = nfs_mounts(mounts);
  if (nmounts == 0)
    return 0;
  DIR *dir = opendir("/proc/self/fdinfo");
  if (!dir)
    return 0;
  int n = 0;
  struct dirent *e;
  while (n < MAX_HELD && (e = readdir(dir))) {
    if (e->d_name[0] == '.')
      continue;
    char path[64], info[4096];
    snprintf(path, sizeof path, "/proc/self/fdinfo/%s", e->d_name);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
      continue;
    ssize_t len = read(fd, info, sizeof info - 1);
    close(fd);
    if (len <= 0)
      continue;
    info[len] = '\0';
    const char *mnt = strstr(info, "mnt_id:");
    int id;
    if (!mnt || sscanf(mnt, "mnt_id: %d", &id) != 1 || !strstr(info, "\nlock:"))
      continue;
    for (int i = 0; i < nmounts; i++)
      if (mounts[i] == id) {
        fds[n++] = atoi(e->d_name);
        break;
      }
  }
  closedir(dir);
  return n;
}

static void pause_ms(long ms) {
  struct timespec ts = { ms / 1000, (ms % 1000) * 1000000 };
  while (nanosleep(&ts, &ts) != 0 && errno == EINTR)
    ;
}

/* Every two seconds, ask the server about each file this process holds a
   lock on. statfs always goes to the server, and any request renews the
   lease. It may wait as long as the network is down. */
static void *probe(void *arg) {
  (void)arg;
  for (;;) {
    pause_ms(2000);
    long long sent = now_ms();
    int fds[MAX_HELD], ok = 1;
    int n = held_nfs_locks(fds);
    for (int i = 0; i < n; i++) {
      struct statfs fs;
      /* EBADF: Nix closed it meanwhile, and with it the lock. */
      if (fstatfs(fds[i], &fs) != 0 && errno != EBADF)
        ok = 0;
    }
    if (ok)
      atomic_store(&last_contact, sent);
  }
  return NULL;
}

static long long silent_ms(void) {
  int fds[MAX_HELD];
  if (held_nfs_locks(fds) == 0)
    return 0;
  return now_ms() - atomic_load(&last_contact);
}

/* Every half second, kill the process if it holds a lock on NFS and the
   server hasn't answered in time. SIGKILL rather than anything Nix could
   catch: cleaning up is what a process that lost its locks mustn't do. */
static void *reap(void *arg) {
  (void)arg;
  for (;;) {
    pause_ms(500);
    long long silent = silent_ms();
    if (silent <= deadline_ms)
      continue;
    char msg[256];
    int len = snprintf(msg, sizeof msg,
                       "nixremote: no answer from the NFS server for %llds while holding a lock "
                       "there; killing process %d before the server's lease runs out and another "
                       "host can take the lock\n",
                       silent / 1000, (int)getpid());
    ssize_t written = write(STDERR_FILENO, msg, (size_t)len);
    (void)written;
    kill(getpid(), SIGKILL);
  }
  return NULL;
}

void nr_watchdog_start(int lease_seconds) {
  /* Once per process: threads don't survive a fork, and Nix's daemon forks
     a process for each connection, which opens the store itself. */
  if (lease_seconds <= 0 || watchdog_pid == getpid())
    return;
  watchdog_pid = getpid();
  deadline_ms = (long long)lease_seconds * 1000 * 2 / 3;
  atomic_store(&last_contact, now_ms());

  /* Keep Nix's signals away from these threads. */
  sigset_t all, old;
  sigfillset(&all);
  pthread_sigmask(SIG_SETMASK, &all, &old);
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_t t;
  if (pthread_create(&t, &attr, probe, NULL) != 0 || pthread_create(&t, &attr, reap, NULL) != 0)
    fprintf(stderr, "nixremote: cannot start the NFS lease watchdog\n");
  pthread_attr_destroy(&attr);
  pthread_sigmask(SIG_SETMASK, &old, NULL);
}

int nr_lock_lost(const char *path) {
  /* The killing thread may not have woken up yet. */
  if (watchdog_pid == getpid() && silent_ms() > deadline_ms)
    return 1;

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

void nr_watchdog_start(int lease_seconds) {
  (void)lease_seconds;
}

int nr_lock_lost(const char *path) {
  (void)path;
  return 0;
}

#endif
