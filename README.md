<p align="center">
  <img src="FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# sqlite-fractalsql by FractalSQLabs

**Stochastic Fractal Search as a SQLite loadable extension.**
Drop a single `.so` (or `.dylib`) next to any SQLite database and get
a continuous-space vector search function that runs entirely inside
the host process.

No server. No sidecar. No network hop. One scalar function, a JSON
document back — sliceable by SQLite's native JSON operators.

## Why

| Scenario | What you get |
| --- | --- |
| **Vercel Edge / AWS Lambda** | Drop `fractalsql.so` into `/api`, use `better-sqlite3`, vector search on a serverless function for $0 |
| **Mobile (React Native, Flutter)** | ARM64 build runs inside your app's SQLite via the C bridge |
| **Turso / libSQL** | Standard SQLite extension ABI — loads wherever `sqlite3_load_extension` is permitted |
| **Privacy** | Data never leaves the device — the search happens in-process |

## Production Ready

- **Static LuaJIT**: libluajit-5.1.a is statically linked into the
  extension. No LuaJIT runtime dependency — the deployed `.so` needs
  only glibc.
- **Multi-arch**: native builds for **AMD64 / x86_64** and **ARM64 /
  aarch64**. Verified on AWS Graviton, Apple Silicon, Ampere Altra,
  Raspberry Pi.
- **`SQLITE_INNOCUOUS`**: declared safe for use in views, triggers,
  and sandboxed/untrusted contexts. Works under SQLite's default
  threading model without extra locking.
- **Minimum glibc 2.38** — aligned with Ubuntu 24.04 / Debian 13 / RHEL
  family.

## The function

```sql
fractal_search(query_vector, k) -> TEXT (JSON)
```

| Arg | Type | Notes |
| --- | --- | --- |
| `query_vector` | TEXT or BLOB | CSV `'1.0,0.5,-0.25'`, bracketed `'[1.0,0.5,-0.25]'`, or a BLOB of packed little-endian float32s |
| `k` | INTEGER | Number of near-optimal candidate points (clamped to 2..10000) |

Returns a JSON document:

```json
{
  "dim": 3,
  "best_point": [0.603, 0.601, 0.002],
  "best_fit": 0.00009,
  "top_k": [
    {"point": [0.603, 0.601, 0.002], "dist": 0.00009},
    {"point": [0.612, 0.588, 0.003], "dist": 0.00021},
    ...
  ]
}
```

Slice it with SQLite's JSON functions — no client-side parsing:

```sql
SELECT
  json_extract(r, '$.best_point')  AS best_point,
  json_extract(r, '$.best_fit')    AS best_fit
FROM (SELECT fractal_search('0.1,0.2,-0.3', 10) AS r);

-- Fan out the top_k as rows for joining against real stored vectors:
WITH result AS (SELECT fractal_search('0.1,0.2,-0.3', 10) AS r)
SELECT value ->> 'dist' AS d
FROM result, json_each(result.r, '$.top_k');
```

---

## Installation

### `.zip` (recommended for edge / serverless / mobile / bundling)

Grab `sqlite-fractalsql-linux-<arch>.zip` from
[GitHub Releases](https://github.com/FractalSQLabs/sqlite-fractalsql/releases).
Inside: `fractalsql.so`, `load_extension.sql`, `LICENSE`, `README.txt`.

```bash
unzip sqlite-fractalsql-linux-arm64.zip
sqlite3 mydb.sqlite \
    -cmd ".load ./fractalsql" \
    -cmd "SELECT fractal_search('0.1,0.2,-0.3', 5);"
```

Drop `fractalsql.so` into your Vercel `/api`, Lambda layer,
mobile app bundle, or Turso deployment artifact.

### Debian / Ubuntu — `.deb`

```bash
sudo apt install ./sqlite3-fractalsql-arm64.deb
```

The post-install step prints the load path. Installs to
`/usr/lib/sqlite3/fractalsql.so`; use:

```sql
SELECT load_extension('/usr/lib/sqlite3/fractalsql');
```

### RHEL / Fedora / Oracle Linux — `.rpm`

```bash
sudo rpm -i sqlite-fractalsql-aarch64.rpm
```

Package name is `sqlite-fractalsql` (matches `sqlite` upstream naming),
vs. `sqlite3-fractalsql` on Debian (matches `sqlite3` binary). Same
install path: `/usr/lib/sqlite3/fractalsql.so`. The RPM claims
`%dir` ownership of `/usr/lib/sqlite3/` since no base package owns it.

### Building from source

```bash
./build.sh amd64   # -> dist/amd64/fractalsql.so (static LuaJIT)
./build.sh arm64   # -> dist/arm64/fractalsql.so (via QEMU)
```

The Dockerfile uses `debian:bookworm-slim` with `build-essential`,
`libluajit-5.1-dev`, `libsqlite3-dev`, and cross-arch builds via
buildx + QEMU. The build verifies statically that `ldd fractalsql.so`
does NOT list libluajit — if it does, the build fails.

For quick local iteration:

```bash
sudo apt install -y build-essential libluajit-5.1-dev libsqlite3-dev pkg-config
make        # dynamic LuaJIT link — faster iteration, not shipped
```

---

## Architectural Performance

The core optimizer is distributed as **pre-compiled LuaJIT bytecode**
embedded in the shared library. No Lua source ships with the
extension.

### No script parsing at runtime

A conventional LuaJIT embedding loads source, invokes the parser,
and generates bytecode before the first opcode executes.
sqlite-fractalsql skips all of this: the bytecode is compiled once at
release time and embedded in `fractalsql.so` as a C byte array.
Loading the optimizer is a `luaL_loadbuffer` over an in-memory buffer
— no tokenizer, no parser, no AST walk. Combined with the per-
connection Lua state held in `sqlite3_user_data`, the parse cost is
paid once per DB connection, not per query.

### Static LuaJIT link

`libluajit-5.1.a` is pulled into the `.so` via
`-Wl,-Bstatic -lluajit-5.1 -Wl,-Bdynamic`. The build verifies
statically that no dynamic luajit reference leaks into the artifact.
This is what makes the extension deployable to Lambda layers, Vercel
Edge Functions, and mobile app bundles with zero LuaJIT provisioning.

### FFI hot loops

Every per-generation SFS computation runs in pre-allocated `double[]`
FFI cdata buffers. Inner loops — fitness evaluation, diffusion walks,
bound checking — JIT-compile to tight machine code comparable to
hand-written C.

---

## Architecture notes

**One Lua state per DB connection.** Stashed in `sqlite3_user_data`
and torn down by the `xDestroy` callback when the function is
unregistered (typically at connection close). SQLite's
`SQLITE_THREADSAFE=1` default serializes calls on a connection, so
the state is accessed without extra locking; separate connections
get separate states.

**Function flags.**
`SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS`.
`DETERMINISTIC` lets SQLite hoist the call out of inner loops when
the same arguments repeat. `INNOCUOUS` marks it safe for views,
triggers, and sandboxed execution (Turso, D1 where permitted).

**BLOB input shape.** Pass a native vector as a BLOB of packed
little-endian float32 values. The extension decodes them directly,
bypassing string parsing. Useful when you already have embeddings
stored as BLOBs.

**Determinism.** LuaJIT's `math.random` is xoshiro256\*\*. Each
connection builds a fresh Lua state, so pinning a seed
(`math.randomseed` in a custom build) yields reproducible results.

---

## Status of advanced features

Shipping v1.0: scalar function, the "Easy Win". A virtual-table
interface for `SELECT * FROM vectors WHERE vector MATCH '...'`
syntax is on the roadmap — it would share the same LuaJIT core and
decode path, but requires a separate xCreate/xConnect/xBestIndex
implementation.

---

## License

MIT. See `LICENSE`.

## Credits & Licensing

FractalSQL is licensed under the MIT License.

This project incorporates third-party components, including:

- **SFS (Simultaneous Fractal Search)** algorithms based on work by
  Hamid Salimi (2014), used under the BSD-3-Clause License.
- **LuaJIT**, used under the MIT License.

Full attribution and license texts can be found in
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).

---

[github.com/FractalSQLabs](https://github.com/FractalSQLabs) · Issues and
PRs welcome.
