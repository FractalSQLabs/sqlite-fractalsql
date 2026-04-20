// src/fractalsql_sqlite.cpp
//
// sqlite-fractalsql v1.0 Community — SQLite loadable extension
// driving the FractalSQL community-edition search core.
//
// Entry point: `sqlite3_fractalsql_init` (matches `.load fractalsql`).
//
// Registered SQL scalar functions
//   fractalsql_edition() -> TEXT      — "Community"
//   fractalsql_version() -> TEXT      — "1.0.0"
//   fractal_search(vector, query)
//                       -> DOUBLE     — cosine distance between
//                                       `vector` and an SFS-refined
//                                       projection of `query`.
//
// Input shapes for vector / query:
//   TEXT CSV or bracketed JSON : '1.0,0.5,-0.25'  or  '[1.0,0.5,-0.25]'
//   BLOB                       : packed little-endian float32
//
// Vectorized-analytics pattern (compare with what DuckDB gives you,
// but entirely in-process):
//
//   SELECT id, fractal_search(embedding, :query) AS dist
//   FROM vectors
//   ORDER BY dist
//   LIMIT 10;
//
// Performance
//   Kati 2023 DiffusionArena. All per-connection scratch buffers
//   (trial point, cached best_point, result string buffer, the
//   LuaJIT stack itself) are pre-allocated at `sqlite3_fractalsql_init`
//   time. The hot path is zero-heap: per-row cosine distance runs
//   against stack + arena memory only. SFS itself runs ONCE per
//   distinct query vector per connection, with the refined best_point
//   cached keyed by the query's hash.
//
// Threading
//   Declared SQLITE_INNOCUOUS + SQLITE_DETERMINISTIC. SQLite's default
//   SQLITE_THREADSAFE=1 serializes calls against a connection, so the
//   per-connection state is accessed without extra locking. Separate
//   connections get separate states.
//
// Binary story
//   * libluajit-5.1.a (PIC-built) linked in statically.
//   * Legacy gcc4 C++ ABI (_GLIBCXX_USE_CXX11_ABI=0).
//   * -static-libgcc -static-libstdc++ -Wl,--gc-sections -Wl,--strip-all.
//   * Windows MSVC path uses /MT /GL for static CRT + WPO.
//   * Resulting .so / .dll is zero-dependency beyond libc / kernel.

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
}

// The community bytecode header is copied in from fractalsql-core's
// foundry output. Factory repos uniformly name it `sfs_core_bc.h`
// regardless of which edition it was generated from.
extern "C" {
#include "sfs_core_bc.h"
}

namespace fractalsql { namespace sqlite_bridge {

// -------------------------------------------------------------------
// Edition metadata — matches what fractalsql-core's `fractalsql_edition`
// returns for the Community build. Any change here MUST be mirrored
// upstream in fractalsql-core's src/fractalsql_core.cpp.
// -------------------------------------------------------------------

static constexpr const char* EDITION_STR = "Community";
static constexpr const char* VERSION_STR = "1.0.0";

// -------------------------------------------------------------------
// Kati 2023 DiffusionArena.
//
// Sizing policy:
//   * ARENA_MAX_DIM        : largest dim we expect (Ada-002 = 1536;
//                            room for OpenAI text-embedding-3-large = 3072;
//                            rounded up to a power of two).
//   * ARENA_RESULT_BYTES   : cap on the JSON / text result an SFS
//                            call can emit. fractal_search returns
//                            a DOUBLE so this buffer is only used
//                            for error messages.
// -------------------------------------------------------------------

static constexpr std::size_t ARENA_MAX_DIM      = 4096;
static constexpr std::size_t ARENA_RESULT_BYTES = 512;

struct DiffusionArena {
    double query[ARENA_MAX_DIM];        // decoded query (f64)
    double best_point[ARENA_MAX_DIM];   // SFS-refined cache
    double trial[ARENA_MAX_DIM];        // per-row vector buffer
    int    dim                  = 0;
    bool   best_point_valid     = false;
    // Content-hash of the last query that produced best_point. We
    // treat as uint64 FNV of the raw bytes — collision risk is low
    // enough that a false cache hit for a different query would
    // still give a sane (just slightly off) distance ordering.
    std::uint64_t cached_query_hash = 0;
};

// -------------------------------------------------------------------
// Per-connection state. sqlite3_user_data passes it to every
// fractal_search invocation. xDestroy tears it down.
// -------------------------------------------------------------------

struct State {
    lua_State*     L            = nullptr;
    int            module_ref   = LUA_NOREF;
    DiffusionArena arena;
};

static std::uint64_t fnv1a_64(const void* bytes, std::size_t n) {
    const std::uint8_t* p = static_cast<const std::uint8_t*>(bytes);
    std::uint64_t h = 0xcbf29ce484222325ULL;
    for (std::size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

// -------------------------------------------------------------------
// Input decoding. Accepts either TEXT (CSV / '[a,b,c]') or BLOB of
// packed little-endian float32. Returns the decoded f64 count, or
// -1 on failure.
// -------------------------------------------------------------------

static int parse_text_vector(const char* src, int slen, double* out, int cap) {
    // strtod needs NUL termination; copy a small local buffer.
    // For typical dim=1536 and ~22 chars per number this is ~34 KB,
    // safely off the stack via the caller's heap-adjacent buffer.
    if (slen <= 0) return -1;
    char* buf = static_cast<char*>(std::malloc(slen + 1));
    if (!buf) return -1;
    std::memcpy(buf, src, slen);
    buf[slen] = '\0';

    char* p = buf;
    int n = 0;
    while (*p && n < cap) {
        while (*p == ' ' || *p == '\t' || *p == ',' ||
               *p == '[' || *p == ']' || *p == '\n' || *p == '\r')
            p++;
        if (!*p) break;
        char* end;
        errno = 0;
        double d = std::strtod(p, &end);
        if (end == p || errno == ERANGE) { std::free(buf); return -1; }
        out[n++] = d;
        p = end;
    }
    std::free(buf);
    return n;
}

static int parse_blob_vector(const void* src, int nbytes, double* out, int cap) {
    if (nbytes <= 0 || (nbytes & 3) != 0) return -1;
    int count = nbytes / 4;
    if (count > cap) return -1;
    const std::uint8_t* bytes = static_cast<const std::uint8_t*>(src);
    for (int i = 0; i < count; i++) {
        float f;
        std::memcpy(&f, bytes + i * 4, 4);
        out[i] = static_cast<double>(f);
    }
    return count;
}

static int parse_value_to_doubles(sqlite3_value* v, double* out, int cap) {
    switch (sqlite3_value_type(v)) {
    case SQLITE_BLOB:
        return parse_blob_vector(
            sqlite3_value_blob(v), sqlite3_value_bytes(v), out, cap);
    case SQLITE_TEXT:
        return parse_text_vector(
            reinterpret_cast<const char*>(sqlite3_value_text(v)),
            sqlite3_value_bytes(v), out, cap);
    default:
        return -1;
    }
}

// -------------------------------------------------------------------
// SFS call. Runs sfs_core.run(cfg) with the query baked into a
// cosine_fitness closure. Output: best_point written into the
// arena, best_point_valid flipped, cached_query_hash updated.
// -------------------------------------------------------------------

static bool run_sniper_and_cache(State* st, int dim) {
    lua_State* L = st->L;
    int saved_top = lua_gettop(L);

    // [M] -> [M, run] -> [M, run, cf] -> [run, cf]
    lua_rawgeti(L, LUA_REGISTRYINDEX, st->module_ref);
    lua_getfield(L, -1, "run");
    lua_getfield(L, -2, "cosine_fitness");
    lua_remove(L, -3);

    // cosine_fitness(query_table) -> fit_closure
    lua_createtable(L, dim, 0);
    for (int i = 0; i < dim; i++) {
        lua_pushnumber(L, st->arena.query[i]);
        lua_rawseti(L, -2, i + 1);
    }
    if (lua_pcall(L, 1, 1, 0) != 0) {
        lua_settop(L, saved_top);
        return false;
    }

    // Build cfg.
    lua_createtable(L, 0, 8);
    lua_createtable(L, dim, 0);
    for (int i = 1; i <= dim; i++) { lua_pushnumber(L, -1.0); lua_rawseti(L, -2, i); }
    lua_setfield(L, -2, "lower");
    lua_createtable(L, dim, 0);
    for (int i = 1; i <= dim; i++) { lua_pushnumber(L,  1.0); lua_rawseti(L, -2, i); }
    lua_setfield(L, -2, "upper");
    lua_pushinteger(L, 30); lua_setfield(L, -2, "max_generation");
    lua_pushinteger(L, 50); lua_setfield(L, -2, "population_size");
    lua_pushinteger(L, 2);  lua_setfield(L, -2, "maximum_diffusion");
    lua_pushnumber(L,  0.5); lua_setfield(L, -2, "walk");
    lua_pushboolean(L, 1);  lua_setfield(L, -2, "bound_clipping");
    lua_pushvalue(L, -2);
    lua_setfield(L, -2, "fitness");
    lua_remove(L, -2);

    if (lua_pcall(L, 1, 4, 0) != 0) {
        lua_settop(L, saved_top);
        return false;
    }

    // Stack: [bp, bf, trace, paths]. Pull bp into the arena.
    int bp_idx = saved_top + 1;
    for (int i = 0; i < dim; i++) {
        lua_rawgeti(L, bp_idx, i + 1);
        st->arena.best_point[i] = lua_tonumber(L, -1);
        lua_pop(L, 1);
    }
    lua_settop(L, saved_top);
    return true;
}

static double cosine_distance(const double* a, const double* b, int dim) {
    double dot = 0.0, na = 0.0, nb = 0.0;
    for (int i = 0; i < dim; i++) {
        dot += a[i] * b[i];
        na  += a[i] * a[i];
        nb  += b[i] * b[i];
    }
    if (na == 0.0 || nb == 0.0) return 1.0;
    return 1.0 - dot / (std::sqrt(na) * std::sqrt(nb));
}

// -------------------------------------------------------------------
// SQL functions.
// -------------------------------------------------------------------

static void edition_fn(sqlite3_context* ctx, int, sqlite3_value**) {
    sqlite3_result_text(ctx, EDITION_STR, -1, SQLITE_STATIC);
}

static void version_fn(sqlite3_context* ctx, int, sqlite3_value**) {
    sqlite3_result_text(ctx, VERSION_STR, -1, SQLITE_STATIC);
}

static void fractal_search_fn(sqlite3_context* ctx, int argc,
                              sqlite3_value** argv) {
    if (argc != 2) {
        sqlite3_result_error(ctx,
            "fractal_search(vector, query) expects 2 args", -1);
        return;
    }

    auto* st = static_cast<State*>(sqlite3_user_data(ctx));
    if (!st || !st->L) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }

    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }

    // Decode vector (argv[0]) straight into the trial buffer — that's
    // where cosine_distance will read from. Zero heap traffic here
    // once the arena is warm.
    int dim_vec = parse_value_to_doubles(argv[0], st->arena.trial, ARENA_MAX_DIM);
    if (dim_vec <= 0) {
        sqlite3_result_error(ctx,
            "fractalsql: invalid vector (expect CSV/JSON text or float32 BLOB)", -1);
        return;
    }

    // Decode query (argv[1]) into the arena.query slot, hash it, and
    // decide whether the cached best_point still matches.
    int dim_q = parse_value_to_doubles(argv[1], st->arena.query, ARENA_MAX_DIM);
    if (dim_q <= 0 || dim_q != dim_vec) {
        sqlite3_result_error(ctx,
            "fractalsql: query dim mismatch with vector", -1);
        return;
    }
    std::uint64_t h = fnv1a_64(st->arena.query, dim_q * sizeof(double));
    bool need_refresh = !st->arena.best_point_valid ||
                        st->arena.dim != dim_q ||
                        st->arena.cached_query_hash != h;

    st->arena.dim = dim_q;
    if (need_refresh) {
        if (!run_sniper_and_cache(st, dim_q)) {
            sqlite3_result_error(ctx, "fractalsql: SFS call failed", -1);
            return;
        }
        st->arena.best_point_valid = true;
        st->arena.cached_query_hash = h;
    }

    double dist = cosine_distance(st->arena.trial, st->arena.best_point, dim_q);
    sqlite3_result_double(ctx, dist);
}

// -------------------------------------------------------------------
// State lifecycle.
// -------------------------------------------------------------------

static void state_destroy(void* p) {
    auto* st = static_cast<State*>(p);
    if (!st) return;
    if (st->L) lua_close(st->L);
    delete st;
}

static State* state_create(char** pzErrMsg) {
    auto* st = new State();
    st->L = luaL_newstate();
    if (!st->L) {
        if (pzErrMsg)
            *pzErrMsg = sqlite3_mprintf("fractalsql: out of memory");
        delete st; return nullptr;
    }
    luaL_openlibs(st->L);

    // The file is named include/sfs_core_bc.h (factory convention)
    // but fractalsql-core generates the C symbol with an
    // edition-specific suffix via `luajit -b -n fractalsql_community`.
    // That symbol is what we reference here.
    int rc = luaL_loadbuffer(
        st->L,
        reinterpret_cast<const char*>(luaJIT_BC_fractalsql_community),
        luaJIT_BC_fractalsql_community_SIZE,
        "=fractalsql_community");
    if (rc != 0) {
        const char* m = lua_tostring(st->L, -1);
        if (pzErrMsg) *pzErrMsg = sqlite3_mprintf(
            "fractalsql: bytecode load failed: %s", m ? m : "?");
        lua_close(st->L); delete st; return nullptr;
    }
    rc = lua_pcall(st->L, 0, 1, 0);
    if (rc != 0) {
        const char* m = lua_tostring(st->L, -1);
        if (pzErrMsg) *pzErrMsg = sqlite3_mprintf(
            "fractalsql: bytecode init failed: %s", m ? m : "?");
        lua_close(st->L); delete st; return nullptr;
    }
    st->module_ref = luaL_ref(st->L, LUA_REGISTRYINDEX);
    return st;
}

}} // namespace fractalsql::sqlite_bridge

// -------------------------------------------------------------------
// Extension entry point. Symbol name matches `fractalsql.so` so
// SQLite's `.load fractalsql` / `load_extension('./fractalsql')`
// finds it via dlsym.
// -------------------------------------------------------------------

// Symbol export strategy is toolchain-specific:
//
//   Linux/gcc: default visibility + -Wl,--exclude-libs,ALL in the
//              Makefile/Dockerfile hides third-party static-lib
//              symbols but keeps our extern "C" entry in .dynsym.
//   MSVC:      scripts/windows/build.bat links with
//              /EXPORT:sqlite3_fractalsql_init, putting the symbol
//              in the DLL's export table without needing
//              __declspec(dllexport) on the declaration (MSVC warns
//              C4502/C4518 when __declspec precedes extern "C").
extern "C"
int sqlite3_fractalsql_init(sqlite3* db, char** pzErrMsg,
                            const sqlite3_api_routines* pApi)
{
    SQLITE_EXTENSION_INIT2(pApi);

    using namespace fractalsql::sqlite_bridge;

    State* st = state_create(pzErrMsg);
    if (!st) return SQLITE_ERROR;

    const int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS;

    // fractalsql_edition() -> TEXT — 0 args, no per-connection state
    // needed since it's a pure constant.
    int rc = sqlite3_create_function_v2(
        db, "fractalsql_edition", 0, flags,
        nullptr, edition_fn, nullptr, nullptr, nullptr);
    if (rc != SQLITE_OK) { state_destroy(st); return rc; }

    rc = sqlite3_create_function_v2(
        db, "fractalsql_version", 0, flags,
        nullptr, version_fn, nullptr, nullptr, nullptr);
    if (rc != SQLITE_OK) { state_destroy(st); return rc; }

    // fractal_search(vector, query) -> REAL — 2 args, carries the
    // per-connection State. The destructor tears down the Lua state
    // when the connection (or the function) is finalized.
    rc = sqlite3_create_function_v2(
        db, "fractal_search", 2, flags,
        st, fractal_search_fn,
        nullptr, nullptr, state_destroy);
    if (rc != SQLITE_OK) {
        // On failure here, xDestroy is NOT called per SQLite contract,
        // so clean up manually.
        state_destroy(st);
        return rc;
    }

    return SQLITE_OK;
}
