@echo off
REM scripts/windows/build-msi.bat
REM
REM Packages fractalsql.dll (pre-built by build.bat) into a Windows
REM MSI using the WiX Toolset.
REM
REM Prerequisites
REM   * WiX Toolset v3.x installed (candle.exe / light.exe on PATH).
REM     Download from https://github.com/wixtoolset/wix3/releases
REM   * dist\windows\fractalsql.dll already built via
REM     scripts\windows\build.bat.
REM   * A README.txt in dist\windows\ (scripts/windows/README.txt
REM     template is shipped in-repo; copy and customize as needed).

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set REPO_ROOT=%~dp0..\..
pushd %REPO_ROOT%

if not exist "dist\windows\fractalsql.dll" (
    echo ==^> ERROR: dist\windows\fractalsql.dll missing — run build.bat first
    popd
    exit /b 1
)
if not exist "dist\windows\README.txt" (
    echo ==^> generating dist\windows\README.txt
    (
      echo FractalSQL for SQLite, Community Edition 1.0.0
      echo.
      echo After install, load the extension in any SQLite session:
      echo.
      echo     sqlite3 mydb.sqlite -cmd ".load fractalsql" ^
          -cmd "SELECT fractalsql_edition();"
      echo.
      echo By default the installer prepends the install folder to
      echo the system PATH so `.load fractalsql` resolves without a
      echo full path. To suppress that step on a silent install:
      echo.
      echo     msiexec /i FractalSQL-SQLite-1.0.0-x64.msi ADDTOPATH=0
      echo.
      echo Three arch variants ship on each release:
      echo     FractalSQL-SQLite-1.0.0-x64.msi    64-bit Intel/AMD
      echo     FractalSQL-SQLite-1.0.0-arm64.msi  native Windows on ARM
      echo     FractalSQL-SQLite-1.0.0-x86.msi    32-bit, pairs with 32-bit sqlite3.exe
    ) > dist\windows\README.txt
)
if not exist "obj" mkdir obj
if not exist "dist\windows" mkdir dist\windows

REM MSI_ARCH drives both candle's -arch flag and the output MSI's
REM filename. Values: x64 (default) | arm64. Native x86 cross-builds
REM would set MSI_ARCH=x86; we don't ship one, but the WXS would
REM cope via $(sys.BUILDARCH).
if "%MSI_ARCH%"=="" set MSI_ARCH=x64

set WXS=scripts\windows\fractalsql.wxs
set MSI=dist\windows\FractalSQL-SQLite-1.0.0-%MSI_ARCH%.msi

echo ==^> MSI_ARCH = %MSI_ARCH%
echo ==^> MSI      = %MSI%

REM -arch propagates into $(sys.BUILDARCH) inside the WXS, which
REM sets <Package Platform="…"/> and keeps ICE80 happy about the
REM component/directory bitness pairing.
candle -nologo -arch %MSI_ARCH% -out obj\fractalsql.wixobj %WXS%
if errorlevel 1 (
    echo ==^> candle failed
    popd & exit /b 1
)

light -nologo ^
      -ext WixUIExtension ^
      -ext WixUtilExtension ^
      -out %MSI% ^
      obj\fractalsql.wixobj
if errorlevel 1 (
    echo ==^> light failed
    popd & exit /b 1
)

echo ==^> Built %MSI%
dir %MSI%

popd
endlocal
