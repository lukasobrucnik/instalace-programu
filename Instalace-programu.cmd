@echo off
rem ==========================================================================
rem  INSTALACE PROGRAMU v3 - spoustec (staci dvakrat kliknout)
rem  Funguje primo z NAS i jako kopie na plose: kdyz vedle sebe nenajde
rem  skript, pouzije ho ze site. O prava spravce si rekne skript sam (UAC).
rem ==========================================================================
setlocal
set "NAS=\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3"
set "PS1=%~dp0InstalaceProgramu.ps1"
if not exist "%PS1%" set "PS1=%NAS%\InstalaceProgramu.ps1"
if not exist "%PS1%" goto chyba

powershell.exe -NoProfile -Command "Unblock-File -LiteralPath '%~f0'" >nul 2>&1
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%" %*
exit /b 0

:chyba
echo.
echo  Instalacni skript se nepodarilo najit:
echo    %NAS%\InstalaceProgramu.ps1
echo.
echo  Co zkusit:
echo    1. Zkontrolujte pripojeni k siti. Mimo kancelar pripojte VPN (FortiClient).
echo    2. Win+R, napiste \\FS01\backup a Enter. Kdyz chce heslo, ucet nema prava - kontaktujte IT.
echo    3. Spustte tento soubor znovu.
echo.
pause
exit /b 1
