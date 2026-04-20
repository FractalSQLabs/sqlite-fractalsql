%global extdir /usr/local/lib/sqlite3
%global docdir %{_docdir}/sqlite-fractalsql

Name:           sqlite-fractalsql
Version:        1.0.0
Release:        1%{?dist}
Summary:        Stochastic Fractal Search SQLite loadable extension (Community)

License:        MIT
URL:            https://github.com/FractalSQLabs/sqlite-fractalsql
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc-c++, make, sqlite-devel
Requires:       sqlite

BuildArch:      %{_arch}

%description
sqlite-fractalsql is a SQLite loadable extension exposing three SQL
scalar functions:

    fractalsql_edition()          -> 'Community'
    fractalsql_version()          -> '1.0.0'
    fractal_search(vector, query) -> REAL (cosine distance to
                                          SFS-refined projection
                                          of the query vector)

Community Edition implements canonical Stochastic Fractal Search
(Salimi 2014) with Gaussian diffusion and greedy sniper selection.
Zero runtime dependencies beyond glibc: LuaJIT, libgcc, and
libstdc++ are statically linked.

Load in any SQLite session:

    SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');

Suitable for edge / serverless deployments (Vercel, AWS Lambda),
Turso / libSQL, Cloudflare D1 (where extensions are permitted),
React Native / Flutter mobile apps, and desktop SQLite usage.

%prep
%setup -q

%build
# The per-arch .so is produced out-of-band by build.sh on a Docker
# builder; this spec just stages it into the RPM.
test -f dist/%{_arch}/fractalsql.so

%install
# /usr/local/lib/sqlite3 is not owned by any base package on RPM
# distros, so we create it and claim %dir ownership below.
install -d -m 0755 %{buildroot}%{extdir}
install -Dm0755 dist/%{_arch}/fractalsql.so \
    %{buildroot}%{extdir}/fractalsql.so
install -Dm0644 sql/load_extension.sql \
    %{buildroot}%{docdir}/load_extension.sql

%files
%license LICENSE
%license LICENSE-THIRD-PARTY
%dir %{extdir}
%{extdir}/fractalsql.so
%{docdir}/load_extension.sql

%post
cat <<'EOF'

sqlite-fractalsql Community installed.

Load inside any SQLite session:

    SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');
    SELECT fractalsql_edition();   -- 'Community'
    SELECT fractalsql_version();   -- '1.0.0'

See /usr/share/doc/sqlite-fractalsql/load_extension.sql for examples.

EOF

%changelog
* Sun Apr 19 2026 FractalSQLabs <ops@fractalsqlabs.io> - 1.0.0-1
- Community Edition: canonical SFS, static LuaJIT + libgcc +
  libstdc++. Legacy gcc4 C++ ABI for universal glibc compatibility.
  Install path moved to /usr/local/lib/sqlite3/. Verified on AMD64
  and ARM64.
