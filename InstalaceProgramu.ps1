#Requires -Version 5.1
<#
.SYNOPSIS
    Instalace programů v3 – instalace firemního softwaru z NAS (offline) se zálohou přes winget.

.DESCRIPTION
    Bez parametrů otevře okno (úvodní kontrola -> hlavní okno). S parametry funguje jako příkazová řádka.
    Skript si sám vyžádá práva správce (UAC) a funguje i ze síťové cesty nebo namapovaného disku.

.PARAMETER NoGui
    Bez okna: nainstaluje povinný základ (+ -Bundle / -Items) a vypíše souhrn.
.PARAMETER Bundle
    ID balíčku z catalog.json (novy-pc, kancelar, spedice, technik, podpora).
.PARAMETER Items
    ID programů z catalog.json, např. -Items 7zip,libreoffice.
.PARAMETER Scope
    rec (podle doporučení, výchozí), all (všichni uživatelé), user (jen přihlášený uživatel).
.PARAMETER DryRun
    Jen vypíše, co by se instalovalo a odkud. Nic neinstaluje.
.PARAMETER Scan
    Prohledá NAS a vypíše rozpoznané programy, verze, vyloučené a nerozpoznané soubory.
.PARAMETER SelfTest
    Otestuje okno bez zobrazení (kontroly, vykreslení, výběr balíčku) a vypíše výsledek.
.PARAMETER ShowConsole
    Konzole zůstane viditelná a vypíše diagnostiku spuštění (používá Diagnostika.cmd).
.PARAMETER NoElevate
    Nežádat o práva správce (jen pro ladění).
.PARAMETER Broker
    Zpracuje požadavky z okna. Spouští jen systémová úloha (SYSTEM) – viz tools\Install-Broker.ps1.
.PARAMETER Elevate
    Vynutit dotaz UAC i tam, kde je systémová úloha (IT: ruční výjimky a programy s průvodcem).
.PARAMETER LanguageReport
    Vypíše uživatele PC (doménový / místní), jejich jazyk a přiřazení z okna Jazyk uživatelů.
.PARAMETER SetLanguage
    Přiřadí jazyk z config\languages.json (např. de-DE) uživatelům v -ForUser a nastaví klávesnici,
    jazyk Windows a formáty. Prázdný řetězec '' přiřazení zruší.
.PARAMETER ForUser
    DOMENA\login, SID nebo default (= noví uživatelé). Pro -SetLanguage.

.NOTES
    Návratové kódy: 0 = OK, 1 = něco selhalo, 2 = chybné parametry / spuštění, 3010 = OK, nutný restart.
    Skript na NAS nic nemaže ani nemění; zapisuje jen do %ProgramData%\InstalaceProgramu.
#>
[CmdletBinding()]
param(
    [switch] $NoGui,
    [string] $Bundle,
    [string[]] $Items = @(),
    [ValidateSet('rec', 'all', 'user')] [string] $Scope = 'rec',
    [switch] $DryRun,
    [switch] $Scan,
    [switch] $SelfTest,
    [switch] $ShowConsole,
    [switch] $NoElevate,
    [switch] $Broker,
    [switch] $Elevate,
    [switch] $LanguageReport,
    [string] $SetLanguage,
    [string[]] $ForUser = @()
)
$ErrorActionPreference = 'Stop'
$exit = @{ Ok = 0; Failed = 1; BadInput = 2; Reboot = 3010 }
# Cesty až tady: ve Windows PowerShell 5.1 bývá $PSScriptRoot ve výchozích hodnotách param() prázdný.
$scriptPath = @($PSCommandPath, $MyInvocation.MyCommand.Path) | Where-Object { $_ } | Select-Object -First 1
$root = Split-Path -Parent $scriptPath
$src = Join-Path $root 'src'
$mode = if ($Broker) { 'broker' } elseif ($PSBoundParameters.ContainsKey('SetLanguage')) { 'setlang' } elseif ($LanguageReport) { 'langreport' } elseif ($Scan) { 'scan' } elseif ($SelfTest) { 'selftest' } elseif ($NoGui -or $DryRun -or $Bundle -or $Items.Count) { 'cli' } else { 'gui' }

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-StartupError {
    # Okno konzole je u GUI skryté – chybu ukážeme v okně a zapíšeme do souboru.
    param([string] $Message)
    $text = "Instalaci programů se nepodařilo spustit.`r`n`r`n$Message`r`n`r`nCo zkusit:`r`n1. Ověřte připojení k síti / VPN a spusťte znovu.`r`n2. Spusťte Diagnostika.cmd – vypíše, co chybí.`r`n3. Pošlete IT tento text (je uložený i v souboru níže)."
    try {
        $f = Join-Path ([IO.Path]::GetTempPath()) ('InstalaceProgramu-chyba-{0:yyyyMMdd-HHmmss}.txt' -f (Get-Date))
        [IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding($true)))
        $text += "`r`n`r`nSoubor: $f"
    } catch { }
    if ($ShowConsole -or $mode -ne 'gui') { Write-Host $text -ForegroundColor Red; return }
    try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($text, 'Instalace programů', 'OK', 'Error') } catch { }
}

function Install-DesktopShortcut {
    # Zástupce s ikonou na veřejné ploše (jen pokud ještě není). Ikona se kopíruje lokálně,
    # aby byla vidět i bez NAS. Cíl: spouštěč na NAS (když je dostupný), jinak ve složce skriptu.
    param($Settings)
    try {
        $desk = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $lnk = Join-Path $desk 'Instalace programů.lnk'
        if (Test-Path -LiteralPath $lnk) { return }
        $launcher = Join-Path $Settings.DeployPath 'Instalace-programu.cmd'
        if (-not $Settings.DeployPath -or -not (Test-Path -LiteralPath $launcher)) { $launcher = Join-Path (ConvertTo-IpUncPath $root) 'Instalace-programu.cmd' }
        if (-not (Test-Path -LiteralPath $launcher)) { return }
        $dataDir = Initialize-IpSecureDirectory -Path $Settings.DataDirectory
        $ico = Join-Path $dataDir 'instalace.ico'
        Copy-Item -LiteralPath (Join-Path $root 'Instalace-programu.ico') -Destination $ico -Force
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = $launcher; $s.IconLocation = "$ico,0"; $s.WindowStyle = 7
        $s.Description = 'Nainstaluje programy z firemního NAS'
        $s.Save()
    } catch { }
}

function Write-Diagnostics {
    $line = { param($l, $v, $ok) Write-Host ('  {0,-24} {1}' -f $l, $v) -ForegroundColor $(if ($ok) { 'Gray' } else { 'Yellow' }) }
    Write-Host ''
    Write-Host '=== Instalace programů v3 – diagnostika spuštění ===' -ForegroundColor Cyan
    & $line 'PowerShell' "$($PSVersionTable.PSVersion)" ($PSVersionTable.PSVersion.Major -ge 5)
    & $line 'Účet' "$([Environment]::UserDomainName)\$([Environment]::UserName)" $true
    & $line 'Práva správce' (Test-Admin) $true
    $brk = try { Import-Module (Join-Path $src 'Common.psm1'); Import-Module (Join-Path $src 'Broker.psm1'); Test-IpBroker -Settings (Get-IpSettings -Path (Join-Path $root 'config\settings.json')) } catch { $false }
    & $line 'Systémová úloha' $(if ($brk) { 'nainstalovaná – instalace bez UAC' } else { 'chybí – bude potřeba UAC (účet správce)' }) ($brk -or (Test-Admin))
    & $line 'Režim vlákna' ([Threading.Thread]::CurrentThread.GetApartmentState()) $true
    & $line 'Skript' $scriptPath $true
    foreach ($f in 'config\settings.json', 'config\catalog.json', 'src\Gui.psm1', 'src\MainWindow.xaml') { $ok = Test-Path -LiteralPath (Join-Path $root $f); & $line $f $(if ($ok) { 'nalezen' } else { 'CHYBÍ – nakopírujte celou složku' }) $ok }
    foreach ($p in Get-ExecutionPolicy -List) { $forced = $p.Scope -in @('MachinePolicy', 'UserPolicy') -and $p.ExecutionPolicy -notin @('Undefined', 'Bypass', 'Unrestricted'); & $line "Policy $($p.Scope)" $p.ExecutionPolicy (-not $forced) }
    Write-Host ''
}

try {
    if ($ShowConsole) { Write-Diagnostics }
    if (-not (Test-Path -LiteralPath (Join-Path $src 'Common.psm1'))) { throw "Chybí složka src vedle skriptu ($src). Nakopírujte celou složku instalátoru, ne jen jeden soubor." }
    Import-Module (Join-Path $src 'Common.psm1')
    Import-Module (Join-Path $src 'Broker.psm1')

    # Bez práv správce a se systémovou úlohou na PC okno běží pod uživatelem a instaluje úloha –
    # žádný dotaz UAC. Bez úlohy (nebo s -Elevate) se jako dřív žádá o práva správce.
    $useBroker = $false
    if ($mode -eq 'gui' -and -not $Elevate -and -not (Test-Admin)) {
        $useBroker = Test-IpBroker -Settings (Get-IpSettings -Path (Join-Path $root 'config\settings.json'))
    }

    # Práva správce: znovu spustit povýšeně (cesta převedená na UNC – namapovaný disk správce nevidí).
    $needsAdmin = ($mode -in @('gui', 'cli') -and -not $DryRun -and -not $useBroker) -or $mode -in @('broker', 'setlang')
    if ($mode -eq 'broker' -and -not (Test-Admin)) { throw 'Režim -Broker spouští jen systémová úloha (SYSTEM).' }
    if ($needsAdmin -and -not $NoElevate -and -not (Test-Admin)) {
        $unc = ConvertTo-IpUncPath $scriptPath
        $pass = @($PSBoundParameters.GetEnumerator() | ForEach-Object {
                if ($_.Key -eq 'Elevate') { }
                elseif ($_.Value -is [switch]) { if ($_.Value.IsPresent) { "-$($_.Key)" } }
                elseif ($_.Value -is [array]) { "-$($_.Key) " + (($_.Value | ForEach-Object { "'$_'" }) -join ',') }
                else { "-$($_.Key) `"$($_.Value)`"" } }) -join ' '
        $hostArgs = "-NoProfile -STA -ExecutionPolicy Bypass " + $(if ($mode -eq 'gui' -and -not $ShowConsole) { '-WindowStyle Hidden ' } else { '-NoExit ' }) + "-File `"$unc`" $pass"
        try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $hostArgs | Out-Null; exit $exit.Ok }
        catch { throw 'Práva správce nebyla udělena (dotaz Windows byl zamítnut nebo účet nemá práva správce). Spusťte znovu a na dotaz klikněte Ano / zadejte účet správce.' }
    }
    if ($mode -eq 'gui' -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(ConvertTo-IpUncPath $scriptPath)`"" | Out-Null
        exit $exit.Ok
    }
    if ($mode -ne 'gui') { try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { } }

    foreach ($m in 'Common', 'NasIndex', 'Health', 'Install', 'Language', 'Broker') { Import-Module (Join-Path $src "$m.psm1") -Force }
    $settings = Get-IpSettings -Path (Join-Path $root 'config\settings.json')
    $catalog = Read-IpCatalog -Path (Join-Path $root 'config\catalog.json')

    switch ($mode) {
        'gui' {
            if (-not $useBroker) { Install-DesktopShortcut -Settings $settings }
            Import-Module (Join-Path $src 'Gui.psm1') -Force
            Show-IpApp -Settings $settings -Catalog $catalog -SrcDir $src -UseBroker:$useBroker
            exit $exit.Ok
        }
        'broker' {
            Invoke-IpBroker -Settings $settings -Catalog $catalog
            exit $exit.Ok
        }
        'selftest' {
            Import-Module (Join-Path $src 'Gui.psm1') -Force
            $r = Show-IpApp -Settings $settings -Catalog $catalog -SrcDir $src -SelfTest
            Write-Host 'Kontroly:' -ForegroundColor Cyan
            $r.Health | ForEach-Object { Write-Host ('  {0,-8} {1,-5} {2}' -f $_.Key, $_.State, $_.Title) }
            Write-Host "Vybráno po balíčku Kancelář: $($r.Selected -join ', ')"
            Write-Host "Řádků uprostřed: $($r.Rows), prvků vpravo: $($r.Catalog), upozornění: $(@($r.Notes).Count)"
            $r.Notes | ForEach-Object { Write-Host "  [$($_[0])] $($_[1])" }
            exit $exit.Ok
        }
        'langreport' {
            $langs = Read-IpLanguages -Settings $settings
            $mi = Get-IpMachineLanguageInfo
            Write-Host ("Počítač {0} · {1} · jazyk systému {2} · pásmo {3} · jazyky Windows: {4}" -f $mi.Computer, $(if ($mi.PartOfDomain) { "doména $($mi.Domain)" } else { 'není v doméně' }), $mi.SystemLocale, $mi.TimeZone, ($mi.UiLanguages -join ', ')) -ForegroundColor Cyan
            $kinds = @{ domain = 'doménový'; local = 'místní'; aad = 'Entra ID'; unknown = '?' }
            foreach ($u in Get-IpUserProfiles -Settings $settings -Languages $langs) {
                $now = if ($u.Current) { "Windows $(if ($u.Current.Ui) { $u.Current.Ui } else { 'výchozí' }), formáty $($u.Current.Culture)" } else { 'nepřihlášen' }
                $as = if ($u.Assigned) { "přiřazeno $($u.Assigned.Language)" } else { '' }
                $sg = if ($u.Suggested) { "návrh $($u.Suggested.Id) ($($u.Suggested.Why))" } else { '' }
                Write-Host ('  {0,-30} {1,-9} {2,-3} {3,-40} {4} {5}' -f $u.Name, $kinds[$u.Kind], $(if ($u.LoggedOn) { '*' } else { '' }), $now, $as, $sg)
            }
            $d = (Read-IpLanguageAssignments -Settings $settings)['default']
            if ($d) { Write-Host "  Noví uživatelé: $($d.Language)" }
            Write-Host '  * = přihlášen' -ForegroundColor DarkGray
            exit $exit.Ok
        }
        'setlang' {
            if (-not $ForUser.Count) { throw 'Zadejte -ForUser DOMENA\login (nebo SID, nebo default).' }
            $changes = foreach ($n in $ForUser) { $a = Resolve-IpAccount -Name $n; @{ Sid = $a.Sid; Account = $a.Name; ProfilePath = $a.ProfilePath; Language = $SetLanguage } }
            $r = Invoke-IpLanguageChanges -Settings $settings -Changes @($changes)
            foreach ($x in $r.Results) { Write-Host ('  {0,-30} {1,-8} {2}' -f $x.Account, $x.State, $x.Message) -ForegroundColor $(if ($x.State -eq 'err') { 'Red' } elseif ($x.State -eq 'warn') { 'Yellow' } else { 'Gray' }) }
            if (@($r.Results | Where-Object State -eq 'err').Count) { exit $exit.Failed }
            if ($r.Reboot) { exit $exit.Reboot }
            exit $exit.Ok
        }
        'scan' {
            $i = Invoke-IpNasScan -Settings $settings -Catalog $catalog
            Write-Host ("Souborů {0}, rozpoznáno {1} programů, {2} ve více verzích, {3} s" -f $i.Stats.Files, $i.Stats.Recognized, $i.Stats.Multi, $i.Stats.Seconds) -ForegroundColor Cyan
            foreach ($it in $catalog.Items) {
                $c = @(Get-IpCandidates -Index $i -ItemId $it.Id)
                $txt = if ($c.Count) { ($c | ForEach-Object { $_.Version + $(if ($_.Recommended) { '*' } else { '' }) + " [$($_.Kind)] $($_.Rel)" }) -join ' | ' } else { '-- jen winget / na NAS nic' }
                Write-Host ('{0,-16} {1}' -f $it.Id, $txt)
            }
            Write-Host 'Nerozpoznané:' -ForegroundColor Yellow; $i.Unrecognized | ForEach-Object { Write-Host "  $($_.Rel)" }
            Write-Host 'Vyloučené:' -ForegroundColor Yellow; $i.Excluded | ForEach-Object { Write-Host "  $($_.Rel) – $($_.Reason)" }
            exit $exit.Ok
        }
        'cli' {
            $ids = New-Object System.Collections.Generic.List[string]
            foreach ($it in $catalog.Items | Where-Object Required) { $ids.Add($it.Id) }
            if ($Bundle) {
                $b = $catalog.Bundles | Where-Object Id -eq $Bundle
                if (-not $b) { throw "Balíček '$Bundle' neexistuje. Dostupné: $(($catalog.Bundles | ForEach-Object Id) -join ', ')" }
                foreach ($x in $b.Items) { if (-not $ids.Contains($x)) { $ids.Add($x) } }
            }
            foreach ($x in $Items) { if (-not $catalog.ById.ContainsKey($x)) { throw "Neznámý program '$x'." }; if (-not $ids.Contains($x)) { $ids.Add($x) } }

            Write-Host 'Kontroluji NAS, internet a obsah NAS…' -ForegroundColor Cyan
            $user = Get-IpLoggedOnUser; $winget = Find-IpWinget
            $nas = Test-IpNas -Settings $settings; $net = Test-IpInternet -Settings $settings
            $index = if ($nas.Ok) { Invoke-IpNasScan -Settings $settings -Catalog $catalog } else { $c = Read-IpIndexCache -Path $settings.IndexPath; if ($c) { $x = ConvertFrom-IpIndexJson $c; $x.FromCache = $true; $x } }
            $health = Get-IpHealth -Settings $settings -Catalog $catalog -Index $index -Nas $nas -Net $net -User $user -WingetPath $winget
            foreach ($h in $health) {
                $col = @{ ok = 'Green'; warn = 'Yellow'; err = 'Red' }[$h.State]
                Write-Host ('  {0,-28} {1}' -f $h.Long, "$($h.Title). $($h.Detail)") -ForegroundColor $col
                if ($h.State -ne 'ok') { $n = 0; foreach ($s in $h.Steps) { $n++; Write-Host "      $n. $($s[0]) – $($s[1])" -ForegroundColor DarkGray } }
            }
            $lang = if ($user) { Get-IpInstallLanguage -Map (Read-IpLanguageAssignments -Settings $settings) -Sid $user.Sid } else { '' }
            $ctx = @{ NasOk = (($health | Where-Object Key -eq 'nas').State -ne 'err'); NetOk = (($health | Where-Object Key -eq 'inet').State -ne 'err'); Winget = $winget; User = $user; Lang = $lang }
            if ($lang) { Write-Host "  Jazyk instalací (winget, Office): $lang" -ForegroundColor DarkGray }
            $plan = New-Object System.Collections.Generic.List[object]; $failed = 0
            Write-Host ''; Write-Host 'Plán:' -ForegroundColor Cyan
            foreach ($id in $ids) {
                $it = $catalog.ById[$id]
                $sc = if ($Scope -eq 'rec') { '' } elseif ($Scope -eq 'user' -and $it.Scope -ne 'machine') { 'user' } else { 'all' }
                $p = Resolve-IpPlanEntry -Item $it -Index $index -Ctx $ctx -Scope $sc
                if ($p.Ok) { $plan.Add($p); Write-Host ('  {0,-26} {1,-7} {2,-14} pro {3}{4}' -f $it.Name, $p.Source, $p.Version, $(if ($p.Scope -eq 'user') { $user.Short } else { 'všechny' }), $(if ($p.Note) { "  ($($p.Note))" } else { '' })) }
                else { $failed++; Write-Host ('  {0,-26} NENAINSTALUJE SE: {1}' -f $it.Name, $p.Reason) -ForegroundColor Red }
            }
            if ($DryRun) { Write-Host ''; Write-Host 'Zkušební režim – nic se neinstaluje.' -ForegroundColor Yellow; exit $exit.Ok }
            $res = @(Invoke-IpInstallBatch -Plan $plan.ToArray() -Ctx $ctx -Settings $settings -State @{ Cancel = $false })
            Write-Host ''
            $res | Format-Table Name, Result, Source, Version, ExitCode, Message -AutoSize | Out-Host
            foreach ($r in $res | Where-Object { $_.Problem }) {
                Write-Host $r.Problem.Title -ForegroundColor Red; Write-Host "  $($r.Problem.What)"
                $n = 0; foreach ($c in $r.Problem.Check) { $n++; Write-Host "  $n. $c" }
            }
            Write-Host "Log: $(Get-IpLogFile)"
            if ($failed -or @($res | Where-Object Result -eq 'Failed').Count) { exit $exit.Failed }
            if (@($res | Where-Object Result -eq 'Reboot').Count) { exit $exit.Reboot }
            exit $exit.Ok
        }
    }
}
catch {
    Show-StartupError -Message ($_ | Out-String)
    exit $exit.BadInput
}
