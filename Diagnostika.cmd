@echo off
rem ==========================================================================
rem  INSTALACE PROGRAMU v3 - diagnosticke spusteni
rem  Stejne jako Instalace-programu.cmd, ale konzole zustane viditelna
rem  a vypise kontrolu prostredi a pripadnou chybu. Pouzijte, kdyz se nic neotevre.
rem  Aplikaci hleda: vedle sebe -> registr HKLM\SOFTWARE\InstalaceProgramu NasPath -> NAS nize.
rem ==========================================================================
setlocal
set "NAS=\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3"
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\InstalaceProgramu" /v NasPath /reg:64 2^>nul ^| find /i "NasPath"') do if not "%%b"=="" set "NAS=%%b"
echo Adresa aplikace na NAS: %NAS%
set "PS1=%~dp0InstalaceProgramu.ps1"
if not exist "%PS1%" set "PS1=%NAS%\InstalaceProgramu.ps1"
if not exist "%PS1%" (
    echo Skript nenalezen ani vedle tohoto souboru, ani na %NAS%.
    echo Zkontrolujte sit / VPN a adresu: reg query HKLM\SOFTWARE\InstalaceProgramu /v NasPath
    pause
    exit /b 1
)
echo Spoustim: %PS1%
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -NoExit -File "%PS1%" -ShowConsole %*
