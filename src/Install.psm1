#Requires -Version 5.1
<#
.SYNOPSIS
    Instalační jádro: co je nainstalované, plán (odkud a pro koho), tichá instalace,
    opakování, záloha NAS -> internet, hlídání oken instalátoru, ověření výsledku.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'NasIndex.psm1')

# Share s instalátory adresovaný IP by Windows řadil do zóny Internet a před spuštěním EXE ukázal
# varování zabezpečení – to by zablokovalo tichou instalaci. Kontrolu zóny pro náš proces vypneme.
$env:SEE_MASK_NOZONECHECKS = '1'

$script:NetworkCodes = @(-2147012894, -2147012867, -2147012889, -2147012891, -2147012744, -2147012865, -2147012866)
$script:WingetAlready = @(-1978335189, -1978335135)

#region Co je nainstalované

function Get-IpInstalledState {
    <#
    .SYNOPSIS
        Pro každou položku katalogu zjistí, zda je nainstalovaná, jakou verzi a pro koho.
    #>
    param([Parameter(Mandatory)] [object[]] $Items, [AllowNull()] $User, [hashtable] $AppxCache)
    $entries = Get-IpUninstallEntries -UserSid $(if ($User) { $User.Sid } else { '' })
    $state = @{}
    $appxNames = $null
    foreach ($it in $Items) {
        $r = [pscustomobject]@{ Installed = $false; Version = ''; Scope = '' }
        if ($it.Type -eq 'font' -or $it.Id -eq 'font-code128') {
            if (Test-Path -LiteralPath (Join-Path $env:windir 'Fonts\code128.ttf')) { $r.Installed = $true; $r.Scope = 'all' }
            elseif ($User -and $User.ProfilePath -and (Test-Path -LiteralPath (Join-Path $User.ProfilePath 'AppData\Local\Microsoft\Windows\Fonts\code128.ttf'))) { $r.Installed = $true; $r.Scope = 'user' }
        }
        elseif ($it.DetectAppx) {
            if ($null -eq $appxNames -and $AppxCache -and $AppxCache['Names'] -and $AppxCache['At'] -and ((Get-Date) - $AppxCache['At']).TotalMinutes -lt 10) { $appxNames = $AppxCache['Names'] }
            if ($null -eq $appxNames) {
                # Výpis balíčků Appx je pomalý (sekundy, na slabších PC i desítky) – okno ho drží 10 min, po instalaci obnoví.
                $appxNames = @{}
                try { Get-AppxPackage -AllUsers -ErrorAction Stop | ForEach-Object { $appxNames[$_.Name] = [string]$_.Version } }
                catch { try { Get-AppxPackage -ErrorAction Stop | ForEach-Object { $appxNames[$_.Name] = [string]$_.Version } } catch { } }   # bez práv správce aspoň balíčky přihlášeného
                try { Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { if (-not $appxNames.ContainsKey($_.DisplayName)) { $appxNames[$_.DisplayName] = [string]$_.Version } } } catch { }
                if ($AppxCache) { $AppxCache['Names'] = $appxNames; $AppxCache['At'] = Get-Date }
            }
            $k = @($appxNames.Keys | Where-Object { $_ -like "*$($it.DetectAppx)*" }) | Select-Object -First 1
            if ($k) { $r.Installed = $true; $r.Version = $appxNames[$k]; $r.Scope = 'all' }
        }
        elseif ($it.Detect) {
            $hits = @($entries | Where-Object { $_.DisplayName -match $it.Detect })
            $best = @($hits | Where-Object Scope -eq 'all') + @($hits) | Select-Object -First 1
            if ($best) { $r.Installed = $true; $r.Version = ConvertTo-IpVersion $best.DisplayVersion; $r.Scope = $best.Scope }
        }
        if ($it.Type -eq 'sophos' -and -not $r.Installed) {
            if (Get-Service -Name 'Sophos MCS Agent', 'SAVService', 'Sophos Endpoint Defense Service' -ErrorAction SilentlyContinue) { $r.Installed = $true; $r.Scope = 'all' }
        }
        $state[$it.Id] = $r
    }
    return $state
}

#endregion

#region Plán: odkud a pro koho

function Resolve-IpPlanEntry {
    <#
    .SYNOPSIS
        Rozhodne, odkud se položka nainstaluje (NAS / winget), kterou verzí a pro koho.
        Když to nejde, vrátí Ok=$false a srozumitelný důvod.
    .PARAMETER Env
        @{ NasOk; NetOk; Winget; User }
    #>
    param([Parameter(Mandatory)] $Item, [AllowNull()] $Index, [Parameter(Mandatory)] [hashtable] $Ctx,
        [string] $Version, [ValidateSet('all', 'user', '')] [string] $Scope = '')
    # @() kolem celého výrazu: jediný kandidát by se jinak rozbalil na objekt bez .Count (PS 5.1).
    $cands = @(if ($Item.Exception) { $Item.Candidate } elseif ($Index) { Get-IpCandidates -Index $Index -ItemId $Item.Id })
    $cand = $null
    if ($cands.Count) {
        if ($Version) { $cand = @($cands | Where-Object Version -eq $Version) | Select-Object -First 1 }
        if (-not $cand) { $cand = @($cands | Where-Object Recommended) + @($cands) | Select-Object -First 1 }
    }
    $nasUsable = $Ctx.NasOk -and $cand -and (-not $Item.NasNeedsInternet -or $Ctx.NetOk) -and -not ($Index -and $Index.FromCache -and -not $Item.Exception)
    $wingetUsable = [bool]($Item.Winget -and $Ctx.NetOk -and $Ctx.Winget)

    $source = $null
    foreach ($s in $Item.Sources) {
        if ($s -eq 'nas' -and $nasUsable) { $source = 'nas'; break }
        if ($s -eq 'winget' -and $wingetUsable) { $source = 'winget'; break }
    }
    if ($Item.Exception -and $nasUsable) { $source = 'nas' }
    if (-not $source) {
        $hasNas = $Item.Sources -contains 'nas' -and $cands.Count; $hasWin = $Item.Sources -contains 'winget' -and $Item.Winget
        $reason =
        if ($hasNas -and $Item.NasNeedsInternet -and -not $Ctx.NetOk -and -not $hasWin) { 'Na NAS je jen online instalátor a internet nefunguje' }
        elseif ($hasNas -and $Item.NasNeedsInternet -and -not $Ctx.NetOk) { 'Internet nefunguje a na NAS je jen online instalátor' }
        elseif ($hasNas -and $hasWin) { 'NAS ani internet teď nejsou dostupné' }
        elseif ($Item.Sources -contains 'nas' -and -not $cands.Count -and -not $hasWin) { 'Instalátor na NAS nebyl nalezen' }
        elseif ($Item.Sources -contains 'nas' -and -not $hasWin) { 'NAS je odpojený a program je jen na NAS' }
        elseif ($hasWin -and $Ctx.NetOk -and -not $Ctx.Winget) { 'Chybí nástroj winget (App Installer)' }
        else { 'Bez internetu nelze – na NAS pro tento program instalátor není' }
        return [pscustomobject]@{ Ok = $false; Reason = $reason; Item = $Item }
    }

    # Pro koho: 'user' jen když to zdroj umí a někdo je přihlášený.
    $want = if ($Scope) { $Scope } elseif ($Item.Scope -eq 'machine') { 'all' } else { $Item.Recommended }
    if ($Item.Scope -eq 'machine') { $want = 'all' }
    $note = ''
    if ($want -eq 'user') {
        if (-not $Ctx.User) { $want = 'all'; $note = 'Nikdo není přihlášený – instaluje se pro všechny.' }
        elseif ($source -eq 'nas') {
            $k = $cand.Kind
            $canUser = $k -in @('font', 'msix', 'inno') -or ($k -eq 'msi' -and $cand.PerUser)
            if (-not $canUser) {
                if ($wingetUsable) { $source = 'winget'; $note = 'Instalátor z NAS neumí instalaci jen pro uživatele – použije se winget.' }
                else { $want = 'all'; $note = 'Instalátor z NAS neumí instalaci jen pro uživatele – instaluje se pro všechny.' }
            }
        }
    }
    return [pscustomobject]@{
        Ok = $true; Item = $Item; Source = $source; Candidate = $(if ($source -eq 'nas') { $cand } else { $null })
        Version = $(if ($source -eq 'nas') { $cand.Version } else { 'winget' }); Scope = $want; Note = $note
        CanFallback = ($source -eq 'nas' -and $wingetUsable)
    }
}

#endregion

#region Spouštění procesů a hlídání oken

function Get-IpTreeWindows {
    # Viditelná okna procesu instalátoru a jeho podprocesů.
    param([int] $RootPid)
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    $kids = @{}; foreach ($p in $all) { $k = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($k)) { $kids[$k] = New-Object System.Collections.Generic.List[int] }; $kids[$k].Add([int]$p.ProcessId) }
    $todo = New-Object System.Collections.Generic.Queue[int]; $todo.Enqueue($RootPid); $seen = @{}
    while ($todo.Count) {
        $id = $todo.Dequeue(); if ($seen.ContainsKey($id)) { continue }; $seen[$id] = 1
        if ($kids.ContainsKey($id)) { foreach ($c in $kids[$id]) { $todo.Enqueue($c) } }
        $gp = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero -and $gp.MainWindowTitle) { [pscustomobject]@{ Pid = $id; Title = $gp.MainWindowTitle } }
    }
}

function Wait-IpProcess {
    <#
    .SYNOPSIS
        Čeká na konec instalátoru. U tiché instalace hlídá okna: známý dialog odklikne podle pravidla
        v katalogu, neznámé okno nahlásí uživateli. Po časovém limitu proces ukončí.
    #>
    param([Parameter(Mandatory)] [Diagnostics.Process] $Process, [int] $TimeoutMinutes, [bool] $Silent,
        $Item, $Settings, $Queue, $State)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $firstSeen = @{}; $reported = @{}; $last = 0
    while (-not $Process.WaitForExit(1000)) {
        if ($sw.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
            & taskkill.exe /PID $Process.Id /T /F 2>$null | Out-Null
            return [pscustomobject]@{ TimedOut = $true; ExitCode = $null }
        }
        if ($Silent -and $sw.Elapsed.TotalSeconds - $last -ge 3) {
            $last = $sw.Elapsed.TotalSeconds
            foreach ($w in @(Get-IpTreeWindows -RootPid $Process.Id)) {
                $key = "$($w.Pid)|$($w.Title)"
                if (-not $firstSeen.ContainsKey($key)) { $firstSeen[$key] = $sw.Elapsed.TotalSeconds; continue }
                if ($reported.ContainsKey($key) -or ($sw.Elapsed.TotalSeconds - $firstSeen[$key]) -lt $Settings.DialogWatchSeconds) { continue }
                $reported[$key] = 1
                $rule = @($Item.Dialogs | Where-Object { $w.Title -match $_.title }) | Select-Object -First 1
                if ($rule) {
                    try {
                        $sh = New-Object -ComObject WScript.Shell
                        if ($sh.AppActivate($w.Pid)) { Start-Sleep -Milliseconds 300; $sh.SendKeys([string]$rule.keys) }
                        Write-IpLog -Settings $Settings -Queue $Queue -Message "  Okno »$($w.Title)« odkliknuto podle pravidla ($($rule.keys))."
                    } catch { }
                }
                else {
                    Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  Instalátor zobrazil okno »$($w.Title)« – pokud čeká na odpověď, je potřeba ho dokončit."
                    Send-IpEvent -Queue $Queue -Data @{ Kind = 'dialog'; Id = $Item.Id; Title = $w.Title; Pid = $w.Pid }
                }
            }
        }
    }
    $Process.WaitForExit()
    return [pscustomobject]@{ TimedOut = $false; ExitCode = [int]$Process.ExitCode }
}

function Start-IpProcess {
    param([Parameter(Mandatory)] [string] $FilePath, [string] $Arguments, [bool] $Visible, $Item, $Settings, $Queue, $State, [bool] $Silent = $true)
    $sa = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = $(if ($Visible) { 'Normal' } else { 'Hidden' }) }
    if ($Arguments) { $sa.ArgumentList = $Arguments }
    $p = Start-Process @sa
    $null = $p.Handle   # bez přístupu k Handle vrací PS 5.1 občas ExitCode = $null
    $tm = if ($Visible) { $Settings.InteractiveTimeoutMinutes } else { $Settings.SilentTimeoutMinutes }
    return Wait-IpProcess -Process $p -TimeoutMinutes $tm -Silent $Silent -Item $Item -Settings $Settings -Queue $Queue -State $State
}

function Wait-IpMsiIdle {
    # Chyba 1618 = běží jiná instalace (často Windows Update). Počká, až skončí.
    param([int] $MaxMinutes = 10)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt $MaxMinutes) {
        $m = $null
        if (-not [Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$m)) { return $true }
        $m.Dispose(); Start-Sleep -Seconds 10
    }
    return $false
}

#endregion

#region Výklad návratových kódů

function Get-IpCodeInfo {
    <#
    .SYNOPSIS
        Návratový kód -> výsledek a srozumitelný popis s postupem pro uživatele.
    #>
    param([AllowNull()] $Code, [string] $Source, [string] $Name)
    $hex = if ($null -ne $Code) { '0x{0:X8}' -f ([int]$Code) } else { '' }
    $r = { param($res, $title, $what, $check) [pscustomobject]@{ Result = $res; Title = $title; What = $what; Check = @($check) } }
    switch ($Code) {
        0 { return & $r 'Success' '' '' @() }
        3010 { return & $r 'Reboot' '' 'Vyžaduje restart.' @() }
        1641 { return & $r 'Reboot' '' 'Instalátor zahájil restart.' @() }
        -1978335223 { return & $r 'Reboot' '' 'Vyžaduje restart.' @() }
        1602 { return & $r 'Failed' "$($Name): instalace byla zrušena" 'Instalace byla zrušena v okně instalátoru (Storno).' @('Pokud to nebyl úmysl, klikněte na Zkusit znovu a průvodce dokončete.') }
        1223 { return & $r 'Failed' "$($Name): instalace byla zrušena" 'Dotaz Windows na oprávnění byl odmítnut.' @('Klikněte na Zkusit znovu a dotaz potvrďte tlačítkem Ano.') }
        1618 { return & $r 'Retry' '' 'Běží jiná instalace.' @() }
        1625 { return & $r 'Failed' "$($Name): instalaci blokují zásady" 'Windows Installer instalaci zakázal skupinovou politikou (kód 1625).' @('Instalaci musí povolit IT (zásady skupiny / Intune).') }
        1638 { return & $r 'Failed' "$($Name): je nainstalovaná jiná verze" 'Na počítači je jiná verze stejného programu a instalátor ji neumí přepsat (kód 1638).' @('V Nastavení → Aplikace odinstalujte stávající verzi programu.', 'Pak klikněte na Zkusit znovu.') }
        1619 { return & $r 'Failed' "$($Name): instalátor nejde otevřít" 'Instalační balíček je poškozený nebo nedostupný (kód 1619).' @('Klikněte na Zkusit znovu.', 'Když chyba trvá, soubor na NAS je poškozený – nahraďte ho novým.') }
        1633 { return & $r 'Failed' "$($Name): nepodporovaný systém" 'Instalátor není pro tuto verzi Windows (32/64 bit) (kód 1633).' @('Na NAS je pravděpodobně jiná varianta instalátoru – kontaktujte IT.') }
        1603 { return & $r 'Failed' "$($Name): instalace selhala (kód 1603)" 'Windows Installer skončil obecnou chybou. Ostatní programy se instalují dál.' @('Pokud Windows čeká na restart po aktualizacích, restartujte a zkuste znovu.', "V Nastavení → Aplikace odinstalujte starší verzi $Name, pokud tam je.", 'Když to nepomůže, pošlete IT log instalace (odkaz dole v průběhu).') }
    }
    if ($script:WingetAlready -contains $Code) { return & $r 'Skipped' '' 'Program už je nainstalovaný v aktuální verzi.' @() }
    if ($script:NetworkCodes -contains $Code) { return & $r 'Network' "$($Name): chyba sítě při stahování" "Stahování z internetu selhalo ($hex)." @('Ověřte internet (kontrolka Internet nahoře).', 'Klikněte na Zkusit znovu.') }
    if ($Code -eq -1978335212 -or $Code -eq -1978335216) { return & $r 'Failed' "$($Name): balíček ve winget nebyl nalezen" "winget pro tento počítač nenašel vhodný instalátor ($hex)." @('Zkuste instalaci znovu později.', 'Pokud chyba trvá, ID balíčku v katalogu je zastaralé – kontaktujte IT.') }
    if ($Code -eq -1978335215) { return & $r 'Failed' "$($Name): stažený soubor nesouhlasí" "Kontrolní součet staženého instalátoru nesouhlasí ($hex) – výrobce právě vydal novou verzi nebo stahování přerušil proxy." @('Zkuste to znovu za několik minut.') }
    return & $r 'Failed' "$($Name): instalace selhala (kód $Code$(if ($hex) { ", $hex" }))" 'Instalátor skončil chybou.' @('Klikněte na Zkusit znovu.', 'Když chyba trvá, pošlete IT log instalace (odkaz dole v průběhu).')
}

#endregion

#region Jednotlivé typy instalace

function Install-IpFont {
    param([Parameter(Mandatory)] [string] $Path, [string] $Scope, $User)
    $name = Split-Path $Path -Leaf
    $family = [IO.Path]::GetFileNameWithoutExtension($Path)
    try { Add-Type -AssemblyName System.Drawing; $pfc = New-Object System.Drawing.Text.PrivateFontCollection; $pfc.AddFontFile($Path); $family = $pfc.Families[0].Name; $pfc.Dispose() } catch { }
    $regName = '{0} ({1})' -f $family, $(if ($Path -match '\.otf$') { 'OpenType' } else { 'TrueType' })
    if ($Scope -eq 'user') {
        $dir = Join-Path $User.ProfilePath 'AppData\Local\Microsoft\Windows\Fonts'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $dest = Join-Path $dir $name
        Copy-Item -LiteralPath $Path -Destination $dest -Force
        $key = "Registry::HKEY_USERS\$($User.Sid)\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name $regName -Value $dest -PropertyType String -Force | Out-Null
    }
    else {
        $dest = Join-Path $env:windir "Fonts\$name"
        if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $Path -Destination $dest -Force }
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -Name $regName -Value $name -PropertyType String -Force | Out-Null
    }
    # Běžícím aplikacím dát vědět o novém písmu (bez toho ho uvidí až po odhlášení).
    try {
        if (-not ('InstalaceProgramu.FontNative' -as [type])) {
            Add-Type -Namespace InstalaceProgramu -Name FontNative -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string f);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
'@
        }
        [void][InstalaceProgramu.FontNative]::AddFontResource($dest)
        $o = [IntPtr]::Zero; [void][InstalaceProgramu.FontNative]::SendMessageTimeout([IntPtr]0xffff, 0x1D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$o)
    } catch { }
}

function New-IpOfficeConfig {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $ProductId, [string] $Language)
    # Jazyk Office: jazyk přiřazený uživateli v okně Jazyk uživatelů, jinak podle Windows.
    $langId = if ($Language -match '^[a-zA-Z]{2,3}-[a-zA-Z]{2,4}$') { $Language.ToLowerInvariant() } else { 'MatchOS' }
    $xml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="$ProductId">
      <Language ID="$langId" />
      <ExcludeApp ID="Access" /><ExcludeApp ID="Groove" /><ExcludeApp ID="Lync" />
      <ExcludeApp ID="Publisher" /><ExcludeApp ID="Teams" />
    </Product>
  </Add>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Updates Enabled="TRUE" />
</Configuration>
"@
    [IO.File]::WriteAllText($Path, $xml, (New-Object Text.UTF8Encoding($false)))
}

function Add-IpTrustedPublisher {
    # Certifikát vydavatele do Důvěryhodných vydavatelů – Windows pak nezobrazí dotaz na instalaci ovladače.
    param([Parameter(Mandatory)] [string] $Path)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate) { return $false }
    $store = New-Object Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
    $store.Open('ReadWrite'); try { $store.Add($sig.SignerCertificate) } finally { $store.Close() }
    return $true
}

function Stop-IpAppProcesses {
    # Zavře běžící program před aktualizací (jinak instalátor čeká na dialog »zavřete aplikaci«).
    param([string[]] $Names, $Settings, $Queue)
    foreach ($n in $Names) {
        $ps = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        if (-not $ps.Count) { continue }
        Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  Zavírám běžící program $n (kvůli instalaci)."
        foreach ($p in $ps) { try { [void]$p.CloseMainWindow() } catch { } }
        Start-Sleep -Seconds 5
        Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Publish-IpShortcut {
    # Zástupce z nabídky Start na plochu (pro všechny = veřejná plocha).
    param($Item, [string] $Scope, $User)
    if (-not $Item.Shortcut) { return }
    $starts = if ($Scope -eq 'user' -and $User) { @(Join-Path $User.ProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs') } else { @(Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') }
    $desk = if ($Scope -eq 'user' -and $User) { Join-Path $User.ProfilePath 'Desktop' } else { [Environment]::GetFolderPath('CommonDesktopDirectory') }
    $lnk = @($starts | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter *.lnk -Recurse -ErrorAction SilentlyContinue } |
            Where-Object { $_.BaseName -match $Item.Shortcut }) | Select-Object -First 1
    if ($lnk -and -not (Test-Path -LiteralPath (Join-Path $desk $lnk.Name))) { Copy-Item -LiteralPath $lnk.FullName -Destination $desk -ErrorAction SilentlyContinue }
}

#endregion

#region Instalace jedné položky

function New-IpResult {
    param($Entry, [string] $Result, $ExitCode, [string] $Message, $Problem, [datetime] $Started, [string] $Source)
    return [pscustomobject]@{
        Id = $Entry.Item.Id; Name = $Entry.Item.Name; Result = $Result; Source = $Source; Version = $Entry.Version; Scope = $Entry.Scope
        ExitCode = $ExitCode; Message = $Message; Problem = $Problem; Seconds = [Math]::Round(((Get-Date) - $Started).TotalSeconds)
    }
}

function Invoke-IpWinget {
    param($Entry, $Ctx, $Settings, $Queue, $State, [string] $WorkDir)
    $it = $Entry.Item
    $wargs = "install --id $($it.Winget) --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity --source winget"
    if ($it.Type -eq 'office') {
        $cfg = Join-Path $WorkDir 'office.xml'; New-IpOfficeConfig -Path $cfg -ProductId $Settings.OfficeProductId -Language ([string]$Ctx.Lang)
        $wargs += " --override `"/configure $cfg`""
    }
    $scopeArg = if ($Entry.Scope -eq 'user') { ' --scope user' } else { ' --scope machine' }
    # Jazyk instalace podle uživatele (okno Jazyk uživatelů); když balíček ten jazyk nemá, zkusí se bez něj.
    $lang = if ([string]$Ctx.Lang -match '^[a-zA-Z]{2,3}-[a-zA-Z]{2,4}$') { [string]$Ctx.Lang } else { '' }
    $attempt = 0; $info = $null; $code = $null; $withScope = $true; $withLocale = [bool]$lang -and $it.Type -ne 'office'
    while ($true) {
        $attempt++
        $full = $wargs + $(if ($withScope -and $it.Type -ne 'office') { $scopeArg } else { '' }) + $(if ($withLocale) { " --locale $lang" } else { '' })
        Write-IpLog -Settings $Settings -Queue $Queue -Message "  winget $full"
        if ($Entry.Scope -eq 'user') {
            $alias = Join-Path $Ctx.User.ProfilePath 'AppData\Local\Microsoft\WindowsApps\winget.exe'
            $exe = if (Test-Path -LiteralPath $alias) { $alias } else { $Ctx.Winget }
            $code = Invoke-IpAsUser -User $Ctx.User -FilePath $exe -Arguments $full -TimeoutMinutes $Settings.SilentTimeoutMinutes
        }
        else {
            $w = Start-IpProcess -FilePath $Ctx.Winget -Arguments $full -Visible $false -Item $it -Settings $Settings -Queue $Queue -State $State
            if ($w.TimedOut) { return [pscustomobject]@{ Code = $null; TimedOut = $true } }
            $code = $w.ExitCode
        }
        $info = Get-IpCodeInfo -Code $code -Source 'winget' -Name $it.Name
        if ($info.Result -eq 'Network' -and $attempt -le 2) {
            $wait = if ($attempt -eq 1) { 5 } else { 15 }
            Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  Síťová chyba ($code), zkouším znovu za $wait s."
            Start-Sleep -Seconds $wait; continue
        }
        if ($info.Result -eq 'Failed' -and $withLocale -and $attempt -le 4) {
            Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  winget v jazyce $lang selhal ($code), zkouším bez určení jazyka."
            $withLocale = $false; continue
        }
        if ($info.Result -eq 'Failed' -and $withScope -and $it.Type -ne 'office' -and $attempt -le 4) {
            # Některé balíčky nemají instalátor pro daný rozsah – zkusit bez určení rozsahu.
            Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  winget s rozsahem selhal ($code), zkouším bez určení rozsahu."
            $withScope = $false; continue
        }
        return [pscustomobject]@{ Code = $code; TimedOut = $false }
    }
}

function Invoke-IpNasInstall {
    param($Entry, $Ctx, $Settings, $Queue, $State, [string] $WorkDir)
    $it = $Entry.Item; $c = $Entry.Candidate
    Send-IpEvent -Queue $Queue -Data @{ Kind = 'item'; Id = $it.Id; Status = 'running'; Message = 'kopíruji z NAS…' }
    $local = Join-Path $WorkDir ([IO.Path]::GetFileName($c.Path))
    Copy-Item -LiteralPath $c.Path -Destination $local -Force
    if ((Get-Item -LiteralPath $local).Length -ne $c.Size) { throw 'Kopie instalátoru z NAS je neúplná (síť se přerušila).' }
    Unblock-File -LiteralPath $local -ErrorAction SilentlyContinue
    $kind = if ($it.Exception -or -not $c.Kind) { Get-IpInstallerKind -Path $local } else { $c.Kind }
    if ($kind -notin @('font', 'zip')) {
        $sig = Get-AuthenticodeSignature -LiteralPath $local -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'HashMismatch') { throw 'Podpis instalátoru nesouhlasí – soubor na NAS je poškozený nebo změněný. Z bezpečnostních důvodů se nespustí.' }
        if ($it.TrustCertificates -and $sig.Status -eq 'Valid') { if (Add-IpTrustedPublisher -Path $local) { Write-IpLog -Settings $Settings -Queue $Queue -Message "  Vydavatel $($sig.SignerCertificate.GetNameInfo('SimpleName', $false)) přidán mezi důvěryhodné (bez dotazu na ovladač)." } }
    }
    $userScope = $Entry.Scope -eq 'user'
    $extra = [string](Get-IpValue $it.Args $(if ($kind -eq 'msi') { 'msi' } elseif ($kind -eq 'msix') { 'msix' } else { 'exe' }) '')

    switch ($kind) {
        'font' { Install-IpFont -Path $local -Scope $Entry.Scope -User $Ctx.User; return 0 }
        'zip' {
            if ($Settings.NoInteractive) { throw 'Archiv je potřeba nainstalovat ručně – v režimu bez práv správce to nejde. Nainstaluje ho IT.' }
            $dest = Join-Path (Initialize-IpSecureDirectory -Path (Join-Path $Settings.DataDirectory 'Rozbalene')) ([IO.Path]::GetFileNameWithoutExtension($local))
            Expand-Archive -LiteralPath $local -DestinationPath $dest -Force
            Start-Process explorer.exe -ArgumentList "`"$dest`""
            return 'manual'
        }
        'msix' {
            if ($userScope) {
                return Invoke-IpAsUser -User $Ctx.User -FilePath 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -Command `"Add-AppxPackage -Path '$local'`"" -TimeoutMinutes $Settings.SilentTimeoutMinutes
            }
            Add-AppxProvisionedPackage -Online -PackagePath $local -SkipLicense -ErrorAction Stop | Out-Null
            if ($Ctx.User) { try { [void](Invoke-IpAsUser -User $Ctx.User -FilePath 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -Command `"Add-AppxPackage -Path '$local'`"" -TimeoutMinutes 15) } catch { } }
            return 0
        }
        'msi' {
            $log = Join-Path $Settings.LogDirectory ('{0}_{1:yyyyMMdd-HHmmss}_msi.log' -f $it.Id, (Get-Date))
            $interactive = ($it.Exception -or $it.Interactive) -and -not $Settings.NoInteractive
            $ui =if ($interactive) { '/qb!' } else { '/qn' }
            $scopeArgs = if ($userScope) { 'ALLUSERS=2 MSIINSTALLPERUSER=1' } else { 'ALLUSERS=1' }
            $a = "/i `"$local`" $ui /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable $scopeArgs $extra /L*v `"$log`""
            Write-IpLog -Settings $Settings -Queue $Queue -Message "  msiexec $a"
            for ($try = 1; $try -le 2; $try++) {
                if ($userScope) { $code = Invoke-IpAsUser -User $Ctx.User -FilePath 'msiexec.exe' -Arguments $a -TimeoutMinutes $Settings.SilentTimeoutMinutes }
                else {
                    $w = Start-IpProcess -FilePath 'msiexec.exe' -Arguments $a -Visible $interactive -Silent (-not $interactive) -Item $it -Settings $Settings -Queue $Queue -State $State
                    if ($w.TimedOut) { return 'timeout' }; $code = $w.ExitCode
                }
                if ($code -ne 1618) { return $code }
                Send-IpEvent -Queue $Queue -Data @{ Kind = 'item'; Id = $it.Id; Status = 'running'; Message = 'běží jiná instalace (1618) – čekám a zkusím znovu' }
                Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message '  Kód 1618: běží jiná instalace, čekám až 10 minut.'
                [void](Wait-IpMsiIdle -MaxMinutes 10)
            }
            return $code
        }
        default {
            $silentArgs = if ($extra) { $extra } else { Get-IpDefaultSilentArgs -Kind $kind }
            if ($kind -eq 'inno' -and $silentArgs -notmatch '/(ALLUSERS|CURRENTUSER)') { $silentArgs += $(if ($userScope) { ' /CURRENTUSER' } else { ' /ALLUSERS' }) }
            $interactive = $it.Exception -or $it.Interactive -or ($it.Type -eq 'office') -or -not $silentArgs
            if ($interactive -and $Settings.NoInteractive) {
                # Systémová úloha běží v neviditelné relaci – okno průvodce by nikdo neviděl a instalace by visela.
                throw 'Instalátor z NAS potřebuje okno průvodce, a to v režimu bez práv správce nejde. Nainstaluje ho IT (spuštění jako správce).'
            }
            if ($interactive) {
                Send-IpEvent -Queue $Queue -Data @{ Kind = 'item'; Id = $it.Id; Status = 'attn'; Message = 'otevřelo se okno instalátoru – dokončete ho' }
                Send-IpEvent -Queue $Queue -Data @{ Kind = 'interactive'; Id = $it.Id; On = $true }
                try {
                    $w = Start-IpProcess -FilePath $local -Arguments $(if ($it.Exception) { '' } else { $extra }) -Visible $true -Silent $false -Item $it -Settings $Settings -Queue $Queue -State $State
                } finally { Send-IpEvent -Queue $Queue -Data @{ Kind = 'interactive'; Id = $it.Id; On = $false } }
                if ($w.TimedOut) { return 'timeout' }
                return $w.ExitCode
            }
            Write-IpLog -Settings $Settings -Queue $Queue -Message "  `"$([IO.Path]::GetFileName($local))`" $silentArgs  [typ: $kind]"
            if ($userScope) { return Invoke-IpAsUser -User $Ctx.User -FilePath $local -Arguments $silentArgs -TimeoutMinutes $Settings.SilentTimeoutMinutes }
            $w = Start-IpProcess -FilePath $local -Arguments $silentArgs -Visible $false -Silent $true -Item $it -Settings $Settings -Queue $Queue -State $State
            if ($w.TimedOut) { return 'timeout' }
            return $w.ExitCode
        }
    }
}

function Install-IpEntry {
    <#
    .SYNOPSIS
        Nainstaluje jednu položku plánu. Při selhání z NAS zkusí winget (když to jde), ověří výsledek.
    #>
    param([Parameter(Mandatory)] $Entry, [Parameter(Mandatory)] [hashtable] $Ctx, [Parameter(Mandatory)] $Settings, $Queue, $State, $Installed)
    $it = $Entry.Item; $started = Get-Date
    Write-IpLog -Settings $Settings -Queue $Queue -Message "▶ $($it.Name) – zdroj: $($Entry.Source), verze: $($Entry.Version), pro: $(if ($Entry.Scope -eq 'user') { $Ctx.User.Short } else { 'všechny' })"
    if ($Entry.Note) { Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  $($Entry.Note)" }

    # Už nainstalováno ve stejné nebo novější verzi -> přeskočit.
    $inst = if ($Installed) { $Installed[$it.Id] } else { $null }
    if ($inst -and $inst.Installed -and -not $it.Exception) {
        $sameScope = $Entry.Scope -eq 'user' -or $inst.Scope -eq 'all'
        $newer = $Entry.Source -eq 'nas' -and $inst.Version -and (Compare-IpVersion $Entry.Version $inst.Version) -gt 0 -and $Entry.Version -notmatch '^\d{4}-\d{2}-\d{2}$'
        if ($sameScope -and -not $newer -and ($Entry.Source -eq 'nas' -or $it.Type -in @('font', 'sophos', 'office'))) {
            Write-IpLog -Settings $Settings -Queue $Queue -Message "  Už nainstalováno ($($inst.Version)) – přeskakuji."
            return New-IpResult -Entry $Entry -Result 'Skipped' -ExitCode 0 -Message ("už nainstalováno $($inst.Version)".Trim()) -Started $started -Source $Entry.Source
        }
    }
    if (@($it.CloseProcesses).Count) { Stop-IpAppProcesses -Names $it.CloseProcesses -Settings $Settings -Queue $Queue }

    $work = New-IpWorkFolder -Settings $Settings -Prefix $it.Id
    $source = $Entry.Source
    try {
        $code = $null
        if ($source -eq 'nas') {
            try { $code = Invoke-IpNasInstall -Entry $Entry -Ctx $Ctx -Settings $Settings -Queue $Queue -State $State -WorkDir $work }
            catch { $code = 'error'; $err = $_.Exception.Message; Write-IpLog -Settings $Settings -Queue $Queue -Level Error -Message "  $err" }
            $ok = $code -eq 0 -or $code -eq 'manual' -or (Get-IpCodeInfo -Code $(if ($code -is [int]) { $code } else { -1 }) -Name $it.Name).Result -in @('Success', 'Reboot', 'Skipped')
            if (-not $ok -and $Entry.CanFallback -and $code -ne 1602 -and $code -ne 1223) {
                Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message "  Z NAS se nepovedlo ($code) – zkouším internet (winget)."
                Send-IpEvent -Queue $Queue -Data @{ Kind = 'item'; Id = $it.Id; Status = 'running'; Message = 'NAS selhal, instaluji z internetu…' }
                $source = 'winget'
            }
        }
        if ($source -eq 'winget') {
            Send-IpEvent -Queue $Queue -Data @{ Kind = 'item'; Id = $it.Id; Status = 'running'; Message = 'stahuji a instaluji z internetu…' }
            $w = Invoke-IpWinget -Entry $Entry -Ctx $Ctx -Settings $Settings -Queue $Queue -State $State -WorkDir $work
            $code = if ($w.TimedOut) { 'timeout' } else { $w.Code }
        }

        if ($code -eq 'manual') { return New-IpResult -Entry $Entry -Result 'Manual' -ExitCode 0 -Message 'archiv rozbalen a složka otevřena – dokončete instalaci ručně' -Started $started -Source $source }
        if ($code -eq 'timeout') {
            $p = [pscustomobject]@{ Title = "$($it.Name): instalace nedoběhla"; What = 'Instalátor se nedokončil v časovém limitu a byl ukončen. Nejspíš čekal na odpověď v okně, které nebylo vidět.'; Tried = 'Hlídání oken a časový limit.'; Check = @('Klikněte na Zkusit znovu – instalátor se tentokrát spustí s viditelným oknem.', 'Pokud se okno objeví, dokončete průvodce.') }
            return New-IpResult -Entry $Entry -Result 'Failed' -ExitCode $null -Message 'časový limit' -Problem $p -Started $started -Source $source
        }
        if ($code -eq 'error') {
            $p = [pscustomobject]@{ Title = "$($it.Name) se nenainstaloval"; What = $err; Tried = $(if ($Entry.CanFallback) { 'Instalace z NAS i z internetu.' } else { 'Instalace z NAS.' }); Check = @('Ověřte připojení k NAS (kontrolka NAS nahoře).', 'Klikněte na Zkusit znovu.') }
            return New-IpResult -Entry $Entry -Result 'Failed' -ExitCode $null -Message $err -Problem $p -Started $started -Source $source
        }
        $info = Get-IpCodeInfo -Code $code -Source $source -Name $it.Name
        if ($info.Result -in @('Failed', 'Network', 'Retry')) {
            $tried = @('Spuštěno ' + $(if ($source -eq 'nas') { 'z NAS' } else { 'z internetu (winget)' }))
            if ($Entry.CanFallback -and $source -eq 'winget') { $tried = @('Instalace z NAS selhala, zkusil se internet (winget).') }
            if ($info.Result -eq 'Network') { $tried += 'Dva další pokusy po 5 a 15 s.' }
            $p = [pscustomobject]@{ Title = $(if ($info.Title) { $info.Title } else { "$($it.Name): instalace selhala" }); What = $info.What; Tried = ($tried -join ' '); Check = $info.Check }
            Write-IpLog -Settings $Settings -Queue $Queue -Level Error -Message "  Selhalo: kód $code. $($info.What)"
            return New-IpResult -Entry $Entry -Result 'Failed' -ExitCode $code -Message "kód $code" -Problem $p -Started $started -Source $source
        }
        if ($info.Result -eq 'Skipped') { return New-IpResult -Entry $Entry -Result 'Skipped' -ExitCode $code -Message 'už nainstalováno (winget)' -Started $started -Source $source }

        # Ověření: je program opravdu v seznamu nainstalovaných?
        $after = Get-IpInstalledState -Items @($it) -User $Ctx.User
        $res = if ($info.Result -eq 'Reboot') { 'Reboot' } else { 'Success' }
        $msg = 'nainstalováno ' + $(if ($source -eq 'nas') { "z NAS ($($Entry.Version))" } else { 'z internetu' }) + $(if ($Entry.Scope -eq 'user') { " · pro $($Ctx.User.Short)" } else { '' })
        if ($res -eq 'Reboot') { $msg += ' · vyžaduje restart' }
        if (($it.Detect -or $it.DetectAppx) -and -not $after[$it.Id].Installed -and -not $it.Exception) {
            $msg += ' · v seznamu programů zatím nenalezen, ověřte'
            Write-IpLog -Settings $Settings -Queue $Queue -Level Warning -Message '  Instalátor skončil úspěšně, ale program zatím není v seznamu nainstalovaných.'
        }
        try { Publish-IpShortcut -Item $it -Scope $Entry.Scope -User $Ctx.User } catch { }
        Write-IpLog -Settings $Settings -Queue $Queue -Level Success -Message "  $msg"
        return New-IpResult -Entry $Entry -Result $res -ExitCode $code -Message $msg -Started $started -Source $source
    }
    catch {
        $m = $_.Exception.Message
        Write-IpLog -Settings $Settings -Queue $Queue -Level Error -Message "  Chyba: $m"
        $p = [pscustomobject]@{ Title = "$($it.Name) se nenainstaloval"; What = $m; Tried = 'Instalace byla přerušena chybou.'; Check = @('Klikněte na Zkusit znovu.', 'Když chyba trvá, pošlete IT log (odkaz dole v průběhu).') }
        return New-IpResult -Entry $Entry -Result 'Failed' -ExitCode $null -Message $m -Problem $p -Started $started -Source $source
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-IpInstallBatch {
    <#
    .SYNOPSIS
        Postupně nainstaluje plán. Používá ho okno (na pozadí) i příkazová řádka.
    .PARAMETER State
        Synchronizovaná hashtable; State.Cancel = $true zastaví dávku po aktuální položce.
    #>
    param([Parameter(Mandatory)] [object[]] $Plan, [Parameter(Mandatory)] [hashtable] $Ctx, [Parameter(Mandatory)] $Settings, $Queue, $State)
    $results = New-Object System.Collections.Generic.List[object]
    $installed = Get-IpInstalledState -Items @($Plan | ForEach-Object Item) -User $Ctx.User
    Write-IpLog -Settings $Settings -Queue $Queue -Message "Spouštím instalaci $($Plan.Count) programů na $([Environment]::MachineName)."
    $i = 0
    foreach ($e in $Plan) {
        $i++
        if ($State -and $State['Cancel']) {
            $r = New-IpResult -Entry $e -Result 'Cancelled' -ExitCode $null -Message 'zastaveno uživatelem' -Started (Get-Date) -Source $e.Source
            $results.Add($r); Send-IpEvent -Queue $Queue -Data @{ Kind = 'result'; Result = $r; Index = $i; Total = $Plan.Count }; continue
        }
        Send-IpEvent -Queue $Queue -Data @{ Kind = 'item'; Id = $e.Item.Id; Status = 'running'; Message = 'připravuji…'; Index = $i; Total = $Plan.Count }
        $r = Install-IpEntry -Entry $e -Ctx $Ctx -Settings $Settings -Queue $Queue -State $State -Installed $installed
        Write-IpAudit -Settings $Settings -Result $r -Queue $Queue
        $results.Add($r)
        Send-IpEvent -Queue $Queue -Data @{ Kind = 'result'; Result = $r; Index = $i; Total = $Plan.Count }
    }
    $c = @{}; foreach ($k in 'Success', 'Reboot', 'Skipped', 'Failed', 'Manual', 'Cancelled') { $c[$k] = @($results | Where-Object Result -eq $k).Count }
    Write-IpLog -Settings $Settings -Queue $Queue -Message ("SOUHRN: nainstalováno {0}, přeskočeno {1}, chyb {2}{3}" -f ($c.Success + $c.Reboot + $c.Manual), $c.Skipped, $c.Failed, $(if ($c.Reboot) { ', vyžaduje restart' } else { '' }))
    Send-IpEvent -Queue $Queue -Data @{ Kind = 'done'; Results = $results.ToArray() }
    return $results.ToArray()
}

#endregion

Export-ModuleMember -Function @(
    'Get-IpInstalledState', 'Resolve-IpPlanEntry', 'Get-IpCodeInfo', 'Install-IpEntry', 'Invoke-IpInstallBatch', 'Install-IpFont', 'Get-IpTreeWindows'
)
