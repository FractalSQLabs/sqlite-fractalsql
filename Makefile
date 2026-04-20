# sqlite-fractalsql Makefile — local (non-Docker) development build.
#
# For shipping multi-arch release artifacts use:
#   ./build.sh        (Docker, static LuaJIT, per-arch .so in ./dist/${arch}/)
#
# This Makefile matches fractalsql-core's build posture:
#
#   * C++ source, compiled with the legacy gcc4 std::string ABI
#     (_GLIBCXX_USE_CXX11_ABI=0) for universal glibc compatibility.
#   * -static-libgcc -static-libstdc++ so the .so doesn't ask for
#     libstdc++.so.6 at runtime.
#   * -Wl,--gc-sections -Wl,--strip-all to trim unused code.
#
# Build:   make
# Install: sudo make install
# Try it:  sqlite3 -cmd ".load ./fractalsql" \
#              -cmd "SELECT fractalsql_edition();"

CXX ?= g++

# SQLite headers (sqlite3ext.h). A SQLite extension does NOT link
# against libsqlite3 — the host SQLite passes its API table via the
# sqlite3_api_routines pointer at load time. Headers only.
SQLITE_CFLAGS := $(shell pkg-config --cflags sqlite3 2>/dev/null)
ifeq ($(strip $(SQLITE_CFLAGS)),)
  SQLITE_CFLAGS := -I/usr/include
endif

# LuaJIT: prefer pkg-config, fall back to common Debian/Ubuntu paths.
LUAJIT_CFLAGS := $(shell pkg-config --cflags luajit 2>/dev/null)
LUAJIT_LIBS   := $(shell pkg-config --libs luajit 2>/dev/null)
ifeq ($(strip $(LUAJIT_CFLAGS)),)
  LUAJIT_CFLAGS := -I/usr/include/luajit-2.1
  LUAJIT_LIBS   := -lluajit-5.1
endif

# Local dev builds dynamic-link LuaJIT for speed. The shipped binary
# is statically linked by build.sh inside Docker.
CXXFLAGS = -std=c++17 -O3 -fPIC \
           -D_GLIBCXX_USE_CXX11_ABI=0 \
           -ffunction-sections -fdata-sections \
           -Wall -Wextra \
           $(SQLITE_CFLAGS) $(LUAJIT_CFLAGS) -Iinclude

# -fvisibility=hidden is deliberately NOT set — sqlite3_fractalsql_init
# must stay in .dynsym so SQLite's loader can dlsym it. Size pressure
# is handled by --gc-sections + --strip-all + --exclude-libs,ALL.
LDFLAGS  = -shared \
           -static-libgcc -static-libstdc++ \
           -Wl,--gc-sections -Wl,--strip-all \
           -Wl,--exclude-libs,ALL \
           $(LUAJIT_LIBS) -lm -ldl -lpthread

TARGET = fractalsql.so
SRCS   = src/fractalsql_sqlite.cpp
OBJS   = $(SRCS:.cpp=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) -o $@ $^ $(LDFLAGS)

%.o: %.cpp include/sfs_core_bc.h
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

install: $(TARGET)
	install -Dm0755 $(TARGET) /usr/local/lib/sqlite3/fractalsql.so

.PHONY: all clean install
