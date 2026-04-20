#!/usr/bin/env bash
#
# scripts/package.sh — interactive-ready packaging pipeline.
#
# What it does
#   Linux: builds fractalsql.deb + fractalsql.rpm from dist/${arch}/
#          fractalsql.so (already produced by ../build.sh). Install
#          target path is /usr/local/lib/sqlite3/fractalsql.so per
#          the v1.0.0 Community brief.
#
#   Windows: on a Linux / macOS host the MSI step is skipped with a
#          pointer to scripts/windows/build.bat + build-msi.bat. The
#          MSI is built by the CI's Windows matrix entry, not here.
#
# Usage
#   scripts/package.sh [amd64|arm64]     (default: amd64)
#
# Output
#   dist/packages/sqlite3-fractalsql-<arch>.deb
#   dist/packages/sqlite3-fractalsql-<arch>.rpm
#   dist/packages/sqlite-fractalsql-linux-<arch>.zip
#     (pure artifact for embedders who don't want a system install)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
ITERATION="1"
DIST_DIR="dist/packages"
mkdir -p "${DIST_DIR}"

PKG_ARCH="${1:-amd64}"
case "${PKG_ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${PKG_ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

case "${PKG_ARCH}" in
    amd64) RPM_ARCH="x86_64" ;;
    arm64) RPM_ARCH="aarch64" ;;
esac

SO="dist/${PKG_ARCH}/fractalsql.so"
if [ ! -f "${SO}" ]; then
    echo "missing ${SO} — run ./build.sh ${PKG_ARCH} first" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Zip (embedders, Vercel edge, Turso, Lambda layers, mobile).
# ---------------------------------------------------------------------
ZIP_OUT="${DIST_DIR}/sqlite-fractalsql-linux-${PKG_ARCH}.zip"
STAGE_ZIP="$(mktemp -d)"
trap 'rm -rf "${STAGE_ZIP}"' EXIT
install -Dm0755 "${SO}"                  "${STAGE_ZIP}/fractalsql.so"
install -Dm0644 sql/load_extension.sql   "${STAGE_ZIP}/load_extension.sql"
install -Dm0644 LICENSE                  "${STAGE_ZIP}/LICENSE"
install -Dm0644 LICENSE-THIRD-PARTY      "${STAGE_ZIP}/LICENSE-THIRD-PARTY"
cat > "${STAGE_ZIP}/README.txt" <<EOF
sqlite-fractalsql ${VERSION} Community (linux-${PKG_ARCH})

Static LuaJIT linked in; legacy gcc4 std::string ABI;
-static-libstdc++ so the .so needs only glibc / libm / libdl.

Quick start:
  sqlite3 mydb.sqlite \\
      -cmd ".load ./fractalsql" \\
      -cmd "SELECT fractalsql_edition();"      -- 'Community'
  sqlite3 mydb.sqlite \\
      -cmd ".load ./fractalsql" \\
      -cmd "SELECT fractalsql_version();"      -- '1.0.0'

SQL surface:
  fractalsql_edition()          TEXT
  fractalsql_version()          TEXT
  fractal_search(vector, query) REAL  (cosine distance to SFS-refined query)
EOF
( cd "${STAGE_ZIP}" && zip -9 -r "${OLDPWD}/${ZIP_OUT}" . > /dev/null )
rm -rf "${STAGE_ZIP}"; trap - EXIT
echo "built ${ZIP_OUT}"

# ---------------------------------------------------------------------
# .deb — installs to /usr/local/lib/sqlite3/fractalsql.so per brief.
# ---------------------------------------------------------------------
DEB_NAME="sqlite3-fractalsql"
DEB_OUT="${DIST_DIR}/${DEB_NAME}-${PKG_ARCH}.deb"

fpm -s dir -t deb \
    -n "${DEB_NAME}" \
    -v "${VERSION}" \
    -a "${PKG_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL SQLite extension, Community Edition" \
    --depends "libc6 (>= 2.38)" \
    --after-install packaging/debian/postinst \
    -p "${DEB_OUT}" \
    ./${SO}=/usr/local/lib/sqlite3/fractalsql.so \
    ./sql/load_extension.sql=/usr/share/doc/sqlite3-fractalsql/load_extension.sql \
    ./LICENSE=/usr/share/doc/sqlite3-fractalsql/LICENSE \
    ./LICENSE-THIRD-PARTY=/usr/share/doc/sqlite3-fractalsql/LICENSE-THIRD-PARTY
echo "built ${DEB_OUT}"

# ---------------------------------------------------------------------
# .rpm — same install path for consistency with the brief.
# ---------------------------------------------------------------------
RPM_NAME="sqlite-fractalsql"
RPM_OUT="${DIST_DIR}/${RPM_NAME}-${PKG_ARCH}.rpm"

STAGE_RPM="$(mktemp -d)"
trap 'rm -rf "${STAGE_RPM}"' EXIT
install -Dm0755 "${SO}" \
    "${STAGE_RPM}/usr/local/lib/sqlite3/fractalsql.so"
install -Dm0644 sql/load_extension.sql \
    "${STAGE_RPM}/usr/share/doc/sqlite-fractalsql/load_extension.sql"
install -Dm0644 LICENSE \
    "${STAGE_RPM}/usr/share/doc/sqlite-fractalsql/LICENSE"
install -Dm0644 LICENSE-THIRD-PARTY \
    "${STAGE_RPM}/usr/share/doc/sqlite-fractalsql/LICENSE-THIRD-PARTY"

fpm -s dir -t rpm \
    -n "${RPM_NAME}" \
    -v "${VERSION}" \
    -a "${RPM_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL SQLite extension, Community Edition" \
    --depends "sqlite" \
    --directories /usr/local/lib/sqlite3 \
    --after-install /dev/stdin \
    -p "${RPM_OUT}" \
    -C "${STAGE_RPM}" \
    usr \
    <<'POSTIN'
cat <<'EOF'

sqlite-fractalsql Community installed at:
    /usr/local/lib/sqlite3/fractalsql.so

Load with:
    sqlite3 mydb.sqlite \
        -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
        -cmd "SELECT fractalsql_edition();"

EOF
POSTIN
rm -rf "${STAGE_RPM}"; trap - EXIT
echo "built ${RPM_OUT}"

# ---------------------------------------------------------------------
# Windows MSI — hand-off note (built by the Windows matrix entry in
# CI, not from this Linux-native script).
# ---------------------------------------------------------------------
cat <<EOF

Windows MSI is built separately via:
    scripts\\windows\\build.bat        (cl.exe with /MT /GL)
    scripts\\windows\\build-msi.bat    (WiX candle + light)

WiX source: scripts/windows/fractalsql.wxs
    * WixUI_InstallDir for interactive install-folder selection
    * Default install: C:\\Program Files\\FractalSQL
    * ADDTOPATH checkbox (default ON) — appends install dir to %PATH%
    * Uninstall removes files AND the PATH entry

EOF

echo
echo "Done. Packages in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
