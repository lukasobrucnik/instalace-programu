@echo off
rem ==========================================================================
rem  INSTALACE PROGRAMU v3 - diagnosticke spusteni
rem  Stejne jako Instalace-programu.cmd, ale konzole zustane viditelna
rem  a vypise kontrolu prostredi a pripadnou chybu. Pouzijte, kdyz se nic neotevre.
rem ==========================================================================
setlocal
set "NAS=\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3"
set "PS1=%~dp0InstalaceProgramu.ps1"
if not exist "%PS1%" set "PS1=%NAS%\InstalaceProgramu.ps1"
if not exist "%PS1%" (
    echo Skript nenalezen ani vedle tohoto souboru, ani na %NAS%.
    echo Zkontrolujte sit / VPN.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -NoExit -File "%PS1%" -ShowConsole %*
