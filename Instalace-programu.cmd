@echo off
rem ==========================================================================
rem  INSTALACE PROGRAMU v3 - spoustec (staci dvakrat kliknout)
rem
rem  Na plochu staci zkopirovat JEN tento soubor. Cela aplikace (backend)
rem  je na NAS a spousti se odtud:
rem      \\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3
rem
rem  Kde spoustec aplikaci hleda (v tomto poradi):
rem    1. vedle sebe (spusteno primo z NAS nebo z mistni kopie systemove ulohy)
rem    2. registr HKLM\SOFTWARE\InstalaceProgramu, hodnota NasPath
rem       (nastavuje okno O instalatoru -> Zmenit adresu na NAS, nebo GPO;
rem        zapisovat smi jen spravce)
rem    3. radek set "NAS=..." nize
rem  O prava spravce si rekne skript sam (UAC), se systemovou ulohou bez UAC.
rem ==========================================================================
setlocal
set "NAS=\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3"
for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\InstalaceProgramu" /v NasPath /reg:64 2^>nul ^| find /i "NasPath"') do if not "%%b"=="" set "NAS=%%b"
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
echo    2. Win+R, napiste \\FS01\backup a Enter. Kdyz chce heslo, ucet nema prava.
echo    3. Adresa aplikace: reg query HKLM\SOFTWARE\InstalaceProgramu /v NasPath
echo       (kdyz neexistuje, plati radek set "NAS=..." v tomto souboru).
echo    4. Spustte Diagnostika.cmd z NAS - vypise, co chybi.
echo.
pause
exit /b 1
