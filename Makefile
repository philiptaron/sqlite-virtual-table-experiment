PREFIX ?= /usr/local

CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -fPIC $(shell pkg-config --cflags sqlite3 libcurl)
LDLIBS += $(shell pkg-config --libs libcurl)

ifeq ($(shell uname),Darwin)
SOEXT = dylib
LDSHARED = -dynamiclib
else
SOEXT = so
LDSHARED = -shared
endif

LIB = libnixremote.$(SOEXT)
OBJS = src/vtab.o src/common.o src/backend_sqlite.o src/backend_http.o src/plugin.o

all: $(LIB)

# No -lsqlite3: every SQLite call goes through the sqlite3_api_routines
# table handed to the extension at load time.
$(LIB): $(OBJS)
	$(CC) $(LDSHARED) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

$(OBJS): src/backend.h

install: $(LIB)
	install -Dm755 $(LIB) $(DESTDIR)$(PREFIX)/lib/$(LIB)
	install -Dm755 scripts/nixremote-mkstate $(DESTDIR)$(PREFIX)/bin/nixremote-mkstate
	install -Dm755 server/nixremote-server $(DESTDIR)$(PREFIX)/bin/nixremote-server

clean:
	rm -f $(OBJS) $(LIB)

.PHONY: all install clean
