@echo off
REM scripts/windows/build.bat
REM
REM Builds fractalsql.dll on Windows with the MSVC toolchain using
REM static CRT (/MT) and whole-program optimization (/GL), matching
REM the Linux posture — zero runtime dependency on the Visual C++
REM Redistributable.
REM
REM Prerequisites
REM   * Visual Studio Build Tools (cl.exe on PATH — run from a
REM     Developer Command Prompt, or invoke vcvarsall.bat first).
REM   * A PIC-equivalent static LuaJIT archive: libluajit-5.1.lib.
REM     Build LuaJIT 2.1 from source with msvcbuild.bat static:
REM         cd LuaJIT\src
REM         msvcbuild.bat static
REM     which emits lua51.lib (rename / alias to libluajit-5.1.lib).
REM   * SQLite SDK headers (sqlite3ext.h). Download from sqlite.org.
REM
REM Environment overrides
REM   LUAJIT_DIR       directory holding lua.h / lualib.h / lauxlib.h
REM                    and libluajit-5.1.lib
REM   SQLITE_DIR       directory holding sqlite3ext.h
REM   OUT_DIR          output directory for fractalsql.dll
REM
REM Invocation
REM   scripts\windows\build.bat
REM   -- or --
REM   set LUAJIT_DIR=C:\deps\LuaJIT\src
REM   set SQLITE_DIR=C:\deps\sqlite-amalgamation-3460000
REM   set OUT_DIR=dist\windows
REM   scripts\windows\build.bat

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

if "%LUAJIT_DIR%"=="" set LUAJIT_DIR=C:\deps\LuaJIT\src
if "%SQLITE_DIR%"=="" set SQLITE_DIR=C:\deps\sqlite
if "%OUT_DIR%"==""    set OUT_DIR=dist\windows

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo ==^> LUAJIT_DIR = %LUAJIT_DIR%
echo ==^> SQLITE_DIR = %SQLITE_DIR%
echo ==^> OUT_DIR    = %OUT_DIR%

REM cl.exe flags:
REM   /MT    static CRT (no MSVC runtime DLL dependency)
REM   /GL    whole program optimization
REM   /LTCG  link-time code generation (needed when /GL is active)
REM   /O2    optimize for speed
REM   /EHsc  standard C++ exception model
REM   /std:c++17
REM   /DWIN32 /D_WINDOWS
REM   /LD    build a DLL
REM
REM The /EXPORT:sqlite3_fractalsql_init line makes the SQLite loader
REM find the entry symbol even with default link visibility.

REM LuaJIT's msvcbuild.bat static emits lua51.lib; the Makefile-based
REM build produces libluajit-5.1.lib. Accept either — prefer the
REM Makefile-style name if both exist.
set LUAJIT_LIB=%LUAJIT_DIR%\libluajit-5.1.lib
if not exist "%LUAJIT_LIB%" (
    if exist "%LUAJIT_DIR%\lua51.lib" set LUAJIT_LIB=%LUAJIT_DIR%\lua51.lib
)
if not exist "%LUAJIT_LIB%" (
    echo ==^> ERROR: no LuaJIT static library in %LUAJIT_DIR%
    echo         ^(expected libluajit-5.1.lib or lua51.lib^)
    exit /b 1
)
echo ==^> LUAJIT_LIB = %LUAJIT_LIB%

REM DO NOT define SQLITE_CORE. It makes sqlite3ext.h emit direct
REM sqlite3_* calls (expecting us to link libsqlite3 statically).
REM Loadable extensions route every sqlite3_* call through the API
REM pointer table installed by SQLITE_EXTENSION_INIT2(pApi), so we
REM stay unlinked from libsqlite3 and let the host process resolve
REM everything at dlopen time.
cl.exe /nologo /MT /GL /O2 /EHsc /std:c++17 ^
    /DWIN32 /D_WINDOWS ^
    /I"%LUAJIT_DIR%" /I"%SQLITE_DIR%" /Iinclude ^
    /LD src\fractalsql_sqlite.cpp ^
    /Fo"%OUT_DIR%\\" ^
    /Fe"%OUT_DIR%\fractalsql.dll" ^
    /link /LTCG ^
        /EXPORT:sqlite3_fractalsql_init ^
        "%LUAJIT_LIB%"

if errorlevel 1 (
    echo.
    echo ==^> BUILD FAILED
    exit /b 1
)

echo.
echo ==^> Built %OUT_DIR%\fractalsql.dll
dir "%OUT_DIR%\fractalsql.dll"

endlocal
