#Requires -Version 5.1
<#
.SYNOPSIS
    Ověří na PC instalaci bez práv správce. Spouštějte jako BĚŽNÝ UŽIVATEL (ne jako správce).
.DESCRIPTION
    Zkontroluje systém, úlohu, oprávnění složek a nechá úlohu jednou naprázdno proběhnout
    (nic se neinstaluje). Tím se ověří i to, že SYSTEM (účet počítače) přečte NAS.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src\Common.psm1')
Import-Module (Join-Path $root 'src\Broker.psm1')
$s = Get-IpSettings -Path (Join-Path $root 'config\settings.json')
$bad = 0
function Show { param([string] $Name, [bool] $Ok, [string] $Detail)
    if (-not $Ok) { $script:bad++ }
    Write-Host ('  [{0}] {1,-34} {2}' -f $(if ($Ok) { ' OK ' } else { 'CHYBA' }), $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
Write-Host ''
Write-Host "=== Test instalace bez práv správce – $env:COMPUTERNAME ===" -ForegroundColor Cyan
Show 'Systém' ($build -ge 17763) "$($os.Caption) $ubr (build $build)$(if ($build -lt 17763) { ' – potřeba Windows 10 1809 nebo novější' })"
Show 'Spuštěno bez práv správce' (-not (Test-IpAdmin)) "$([Environment]::UserDomainName)\$([Environment]::UserName)$(if (Test-IpAdmin) { ' – spusťte test jako běžný uživatel, jinak neověří oprávnění' })"
foreach ($p in Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' }) {
    $ok = $p.ExecutionPolicy -in 'Undefined', 'Bypass', 'Unrestricted', 'RemoteSigned'
    Show "Zásada spouštění ($($p.Scope))" $ok "$($p.ExecutionPolicy)$(if (-not $ok) { ' – GPO vynucuje podepsané skripty, -ExecutionPolicy Bypass nepomůže' })"
}

$t = Get-IpBrokerTask -Settings $s
Show 'Úloha je vidět' ([bool]$t) $(if ($t) { "\$($s.BrokerTaskName)" } else { 'chybí – GPO ještě neproběhlo (gpupdate /force jako správce) nebo nemá uživatel právo číst' })
$paths = Get-IpBrokerPaths $s
Show 'Složka požadavků' (Test-Path -LiteralPath $paths.Requests) $paths.Requests
Show 'Místní kopie aplikace' (Test-Path -LiteralPath (Join-Path $s.AppDirectory 'InstalaceProgramu.ps1')) $s.AppDirectory

# Uživatel smí do Requests zapsat, ale nesmí do aplikace ani do Status.
$probe = Join-Path $paths.Requests ('test-' + [guid]::NewGuid().ToString('N') + '.tmp')
$canReq = try { [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force; $true } catch { $false }
Show 'Uživatel smí podat požadavek' $canReq 'zápis do složky Requests'
if (Test-Path -LiteralPath $s.AppDirectory) {
    $canApp = try { $f = Join-Path $s.AppDirectory 'test.tmp'; [IO.File]::WriteAllText($f, 'x'); Remove-Item $f -Force; $true } catch { $false }
    Show 'Uživatel NEsmí měnit aplikaci' (-not $canApp) $(if ($canApp) { 'POZOR: uživatel může měnit skript, který běží jako SYSTEM' } else { 'zápis odepřen – správně' })
}
if (Test-Path -LiteralPath $paths.Requests) {
    $canList = try { $null = Get-ChildItem -LiteralPath $paths.Requests -ErrorAction Stop; $true } catch { $false }
    Show 'Uživatel NEvidí cizí požadavky' (-not $canList) $(if ($canList) { 'výpis složky povolen' } else { 'výpis odepřen – správně' })
}

$wg = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*' -Directory -ErrorAction SilentlyContinue).Count -or [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
Show 'winget (App Installer)' $wg $(if ($wg) { 'nalezen' } else { 'nenalezen – programy jen z internetu nepůjdou, z NAS ano' })

if ($t) {
    Write-Host '  ... spouštím úlohu naprázdno (nic se neinstaluje), max. 3 minuty' -ForegroundColor Gray
    $before = $t.LastRunTime
    $runErr = ''
    $ran = try { [void]$t.Run($null); $true } catch { $runErr = $_.Exception.Message; $false }
    Show 'Uživatel smí úlohu spustit' $ran $(if ($ran) { 'spuštěno' } else { "odepřeno: $runErr" })
    if ($ran) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        do { Start-Sleep -Seconds 2; $t = Get-IpBrokerTask -Settings $s } while ($sw.Elapsed.TotalSeconds -lt 180 -and ($t.State -in 2, 4 -or $t.LastRunTime -eq $before))
        $r = $t.LastTaskResult
        Show 'Úloha proběhla jako SYSTEM' ($r -eq 0) $(if ($r -eq 0) { 'výsledek 0' } else { "výsledek $r (0x{0:X8}) – viz C:\ProgramData\InstalaceProgramu\Logs" -f $r })
    }
}

Write-Host ''
if ($bad) { Write-Host "Nalezeno chyb: $bad" -ForegroundColor Red; exit 1 }
Write-Host 'Vše v pořádku. Zkuste v okně nainstalovat třeba 7-Zip – nesmí se objevit dotaz na heslo.' -ForegroundColor Green
exit 0
