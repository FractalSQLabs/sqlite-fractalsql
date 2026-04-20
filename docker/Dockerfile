# syntax=docker/dockerfile:1.7
#
# sqlite-fractalsql Factory build.
#
# Produces ONE .so per target architecture (driven by --platform):
#   /fractalsql.so
#
# Build posture
#   C++ source compiled with the legacy gcc4 std::string ABI
#   (-D_GLIBCXX_USE_CXX11_ABI=0), -static-libgcc -static-libstdc++
#   so there's no runtime libstdc++.so.6 dependency, and the Kati
#   DiffusionArena / zero-heap patterns live entirely in the .cpp.
#
# Static-linking strategy
#   We need libluajit-5.1.a built with -fPIC so it can be pulled
#   into a shared object. Debian's libluajit-5.1-dev ships the
#   archive WITHOUT -fPIC (Debian policy for separate static/shared
#   archives), which makes it unusable here — the linker rejects it
#   with `R_X86_64_TPOFF32 ... can not be used when making a shared
#   object`.
#
#   Fix: compile LuaJIT from source with XCFLAGS="-fPIC" BUILDMODE=static
#   inside this builder stage. Adds ~30s to the build; guarantees a
#   usable archive on every arch.
#
#   The resulting fractalsql.so has no dynamic dep on libluajit or
#   libstdc++ at all — verified via ldd in the build step.
#
#   SQLite itself provides its API via the sqlite3_api_routines pointer
#   at load time, so there's no libsqlite3 linkage either.
#
# Usage:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target export \
#     --output type=local,dest=./dist/amd64 \
#     -f docker/Dockerfile .

ARG LUAJIT_REF=v2.1

FROM debian:bookworm-slim AS builder
ARG LUAJIT_REF

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        g++ \
        libsqlite3-dev \
        pkg-config \
        ca-certificates \
        git \
 && rm -rf /var/lib/apt/lists/*

# Build a PIC-enabled libluajit-5.1.a from source. BUILDMODE=static
# skips the .so build we don't need. Install to /usr/local so the
# subsequent compile step picks it up on standard search paths.
#
# Explicitly unset TARGET_ARCH — LuaJIT's Makefile uses that variable
# as a gcc flag knob; any outer env value (common in CI) makes gcc
# try to treat it as a linker input.
RUN set -eux; \
    unset TARGET_ARCH; \
    git clone --depth 1 --branch "${LUAJIT_REF}" \
        https://github.com/LuaJIT/LuaJIT.git /tmp/luajit; \
    cd /tmp/luajit; \
    make -j"$(nproc)" TARGET_ARCH= XCFLAGS="-fPIC" BUILDMODE=static; \
    make install PREFIX=/usr/local; \
    cd /; rm -rf /tmp/luajit; \
    ls -l /usr/local/lib/libluajit-5.1.a

WORKDIR /build
COPY src/     /build/src/
COPY include/ /build/include/

RUN set -eux; \
    SQLITE_CFLAGS="$(pkg-config --cflags sqlite3 2>/dev/null || echo '-I/usr/include')"; \
    echo "SQLITE_CFLAGS='${SQLITE_CFLAGS}'"; \
    # No -fvisibility=hidden — we need sqlite3_fractalsql_init to
    # land in .dynsym so SQLite's loader can dlsym it. With
    # --gc-sections + --strip-all the binary stays tiny anyway,
    # and --exclude-libs,ALL (added below) keeps third-party static
    # lib symbols out of the export table.
    g++ -std=c++17 -Wall -Wextra -O3 -fPIC \
        -D_GLIBCXX_USE_CXX11_ABI=0 \
        -ffunction-sections -fdata-sections \
        ${SQLITE_CFLAGS} \
        -I/usr/local/include/luajit-2.1 \
        -Iinclude \
        -shared \
        -o /build/fractalsql.so \
        src/fractalsql_sqlite.cpp \
        /usr/local/lib/libluajit-5.1.a \
        -static-libgcc -static-libstdc++ \
        -Wl,--gc-sections -Wl,--strip-all \
        -Wl,--exclude-libs,ALL \
        -lm -ldl -lpthread; \
    # Zero-footprint verification. Any forbidden dynamic ref fails
    # the build.
    if ldd /build/fractalsql.so 2>/dev/null | grep -Ei 'luajit|stdc\+\+'; then \
        echo "FAIL: dynamic luajit or libstdc++ reference" >&2; exit 1; \
    fi; \
    # cxx11 symbol leakage (legacy ABI means zero __cxx11 matches).
    cxx11_n=$(nm -D /build/fractalsql.so 2>/dev/null | c++filt \
              | grep -c '__cxx11::basic_string' || true); \
    if [ "$cxx11_n" != "0" ]; then \
        echo "FAIL: $cxx11_n __cxx11 symbols (legacy ABI violated)" >&2; \
        exit 1; \
    fi; \
    sz=$(stat -c %s /build/fractalsql.so); \
    echo "ok: size=$sz bytes, cxx11_refs=$cxx11_n"; \
    ldd /build/fractalsql.so

# Scratch export so buildx --output=local drops just the .so.
FROM scratch AS export
COPY --from=builder /build/fractalsql.so /fractalsql.so
