# Vývoj: spustí okno mimo viditelnou plochu (bez práv správce – nic neinstaluje), otevře zvolenou
# obrazovku, uloží obsah oken do PNG a samo se zavře. Nic nezachytává z obrazovky uživatele.
param([string] $Views = 'start,main,status,nas', [string] $OutDir = $env:TEMP, [int] $TimeoutSeconds = 150)
$root = Split-Path -Parent $PSScriptRoot
foreach ($v in ($Views -split ',')) {
    $env:IP_DEBUG = $v; $env:IP_SNAP_DIR = $OutDir
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\InstalaceProgramu.ps1`" -NoElevate" -PassThru
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { Stop-Process -Id $p.Id -Force; "$v : ČASOVÝ LIMIT" ; continue }
    "$v : konec (kód $($p.ExitCode))"
}
$env:IP_DEBUG = ''; $env:IP_SNAP_DIR = ''
Get-ChildItem $OutDir -Filter 'ip-*.png' | Sort-Object LastWriteTime | ForEach-Object { "  $($_.Name)  $([int]($_.Length/1KB)) kB" }
