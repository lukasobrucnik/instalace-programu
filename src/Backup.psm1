#Requires -Version 5.1
<#
.SYNOPSIS
    Záloha a přenos dat uživatele: plocha, dokumenty, stažené soubory, obrázky a profily prohlížečů
    (jen záložky, nebo celý profil – záložky, hesla, historie, rozšíření, nastavení). Obnova na jiném PC.
.DESCRIPTION
    Záloha:  <cíl>\<POČÍTAČ>_<login>_<yyyyMMdd-HHmm>\   (cíl = settings.json backupRoot nebo zvolená složka)
             backup.json   co se zálohovalo, odkud, kdy, kdo a s jakým výsledkem
             _robocopy.log podrobný log kopírování
    Obnova:  ze složky zálohy do profilu vybraného uživatele na tomto PC. Novější soubory se nepřepisují.
             Před obnovou celého profilu prohlížeče se stávající profil přejmenuje (*.pred-obnovou-<datum>).
    Kopíruje robocopy (Windows 10 i 11). Jako správce v režimu zálohování (/B) – přečte i profily ostatních.
    Bez práv správce jen vlastní profil.
.NOTES
    Hesla v Chrome / Edge / Brave / Opera šifruje Windows (DPAPI) klíčem účtu. Proto se s celým profilem
    zálohují i klíče DPAPI (AppData\Roaming\Microsoft\Protect\<SID>). Na jiném PC je umí použít jen STEJNÝ
    účet (doménový). Pro jiný účet hesla přeneste synchronizací prohlížeče nebo exportem do CSV.
    Firefox má hesla přímo v profilu (logins.json + key4.db) – přenesou se vždy.
    Pozor: v řetězcích v uvozovkách "" nepoužívat české „“ – PowerShell je bere jako konec řetězce.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:ManifestName = 'backup.json'

# Složky uživatele. Reg = název hodnoty v User Shell Folders (podle něj se najde i přesměrovaná složka / OneDrive).
$script:Folders = @(
    [pscustomobject]@{ Id = 'desktop'; Name = 'Plocha'; Reg = 'Desktop'; Default = 'Desktop'; Dir = 'Plocha'; On = $true }
    [pscustomobject]@{ Id = 'documents'; Name = 'Dokumenty'; Reg = 'Personal'; Default = 'Documents'; Dir = 'Dokumenty'; On = $true }
    [pscustomobject]@{ Id = 'downloads'; Name = 'Stažené soubory'; Reg = '{374DE290-123F-4565-9164-39C4925E467B}'; Default = 'Downloads'; Dir = 'Stazene'; On = $true }
    [pscustomobject]@{ Id = 'pictures'; Name = 'Obrázky'; Reg = 'My Pictures'; Default = 'Pictures'; Dir = 'Obrazky'; On = $false }
)

# Prohlížeče. Rel = data prohlížeče v profilu uživatele.
$script:Browsers = @(
    [pscustomobject]@{ Id = 'chrome'; Name = 'Google Chrome'; Rel = 'AppData\Local\Google\Chrome\User Data'; Kind = 'chromium'; Proc = 'chrome'; Dir = 'Prohlizece\Chrome' }
    [pscustomobject]@{ Id = 'edge'; Name = 'Microsoft Edge'; Rel = 'AppData\Local\Microsoft\Edge\User Data'; Kind = 'chromium'; Proc = 'msedge'; Dir = 'Prohlizece\Edge' }
    [pscustomobject]@{ Id = 'brave'; Name = 'Brave'; Rel = 'AppData\Local\BraveSoftware\Brave-Browser\User Data'; Kind = 'chromium'; Proc = 'brave'; Dir = 'Prohlizece\Brave' }
    [pscustomobject]@{ Id = 'opera'; Name = 'Opera'; Rel = 'AppData\Roaming\Opera Software\Opera Stable'; Kind = 'chromium'; Proc = 'opera'; Dir = 'Prohlizece\Opera' }
    [pscustomobject]@{ Id = 'firefox'; Name = 'Mozilla Firefox'; Rel = 'AppData\Roaming\Mozilla\Firefox'; Kind = 'firefox'; Proc = 'firefox'; Dir = 'Prohlizece\Firefox' }
)
$script:Dpapi = [pscustomobject]@{ Id = 'dpapi'; Name = 'Klíče Windows pro hesla prohlížečů (DPAPI)'; Rel = 'AppData\Roaming\Microsoft\Protect'; Dir = 'DPAPI' }

# Mezipaměti a dočasná data – nezálohují se (velké a po obnově se vytvoří znovu).
$script:ChromiumSkip = @('Cache', 'Code Cache', 'GPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
    'CacheStorage', 'ScriptCache', 'Crashpad', 'component_crx_cache', 'extensions_crx_cache', 'Safe Browsing', 'optimization_guide_model_store', 'BrowserMetrics',
    'OnDeviceHeadSuggestModel', 'screen_ai', 'SODA', 'SODALanguagePacks', 'Snapshots', 'Crash Reports', 'WidevineCdm', 'hyphen-data', 'ZxcvbnData')
$script:FirefoxSkip = @('crashes', 'minidumps', 'Crash Reports', 'Pending Pings', 'datareporting', 'saved-telemetry-pings', 'cache2', 'startupCache', 'thumbnails', 'shader-cache')
$script:FileSkip = @('~$*', '*.tmp', 'Thumbs.db', 'LOCK', 'lockfile', 'parent.lock', '.parentlock', 'SingletonLock', 'SingletonCookie', 'SingletonSocket')

#region Uživatelé a jejich složky

function Get-IpBkMachineSid {
    try { $u = @(Get-LocalUser -ErrorAction Stop)[0]; if ($u) { return $u.SID.AccountDomainSid.Value } } catch { }
    try {
        $u = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop)[0]
        return (New-Object Security.Principal.SecurityIdentifier $u.SID).AccountDomainSid.Value
    } catch { return '' }
}

function Get-IpBkProcessOwners {
    # Procesy prohlížečů (a explorer.exe) -> SID vlastníka. Výsledek: @{ SID = @{ název = počet } }
    $h = @{}
    $names = @(@($script:Browsers | ForEach-Object { "$($_.Proc).exe" }) + 'explorer.exe')
    $filter = ($names | ForEach-Object { "Name='$_'" }) -join ' OR '
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)) {
            try {
                $s = [string](Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid
                if (-not $s) { continue }
                if (-not $h.ContainsKey($s)) { $h[$s] = @{} }
                $n = [IO.Path]::GetFileNameWithoutExtension([string]$p.Name).ToLowerInvariant()
                $h[$s][$n] = 1 + [int]$h[$s][$n]
            } catch { }
        }
    } catch { }
    return $h
}

function Get-IpBackupUsers {
    <#
    .SYNOPSIS
        Uživatelé s profilem na tomto PC (doménový / místní / Entra ID), přihlášený, poslední použití.
    #>
    $machineSid = Get-IpBkMachineSid
    $owners = Get-IpBkProcessOwners
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { continue }
        $prop = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $prop -or -not $prop.PSObject.Properties['ProfileImagePath']) { continue }
        $path = [Environment]::ExpandEnvironmentVariables([string]$prop.ProfileImagePath)
        $folder = Split-Path -Leaf $path
        if ($folder -match '^(defaultuser\d+|TEMP)$' -or -not (Test-Path -LiteralPath $path)) { continue }
        $name = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { '' }
        $so = New-Object Security.Principal.SecurityIdentifier $sid
        $kind = if ($sid -like 'S-1-12-1-*') { 'aad' }
        elseif ($machineSid -and $so.AccountDomainSid) { if ($so.AccountDomainSid.Value -eq $machineSid) { 'local' } else { 'domain' } }
        elseif ($name) { if (($name -split '\\')[0] -eq [Environment]::MachineName) { 'local' } else { 'domain' } }
        else { 'unknown' }
        $last = try { (Get-Item -LiteralPath (Join-Path $path 'NTUSER.DAT') -Force -ErrorAction Stop).LastWriteTime } catch { $null }
        $list.Add([pscustomobject]@{
                Sid = $sid; Name = $(if ($name) { $name } else { $folder }); Short = $(if ($name) { ($name -split '\\')[-1] } else { $folder }); Resolved = [bool]$name
                Kind = $kind; ProfilePath = $path; LastUse = $last; Self = ($sid -eq $me)
                LoggedOn = [bool]($owners.ContainsKey($sid) -and $owners[$sid].ContainsKey('explorer')); Loaded = (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")
            })
    }
    return @($list | Sort-Object @{ Expression = { -not $_.LoggedOn } }, @{ Expression = { $_.Kind -ne 'domain' } }, Name)
}

function Get-IpUserShellFolders {
    <#
    .SYNOPSIS
        Skutečné cesty k ploše, dokumentům, staženým a obrázkům uživatele (i přesměrované / OneDrive).
        Čte registr uživatele; když není načtený, jako správce ho dočasně načte (reg load).
    #>
    param([Parameter(Mandatory)] [string] $Sid, [Parameter(Mandatory)] [string] $ProfilePath)
    $h = @{}
    $readKey = {
        param([Microsoft.Win32.RegistryKey] $Key)
        if (-not $Key) { return }
        try {
            foreach ($f in $script:Folders) {
                $v = $Key.GetValue($f.Reg, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if (-not $v) { continue }
                # %USERPROFILE% patří uživateli, ne účtu, pod kterým běží aplikace.
                $p = [regex]::Replace([string]$v, '%USERPROFILE%', ($ProfilePath -replace '\$', '$$$$'), 'IgnoreCase')
                if ($p -match '%') { $p = [Environment]::ExpandEnvironmentVariables($p) }
                $h[$f.Id] = $p.TrimEnd('\')
            }
        }
        finally { $Key.Dispose() }
    }
    $sub = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$Sid") {
        & $readKey ([Microsoft.Win32.Registry]::Users.OpenSubKey("$Sid\$sub"))
    }
    elseif (Test-IpAdmin) {
        $dat = Join-Path $ProfilePath 'NTUSER.DAT'
        if (Test-Path -LiteralPath $dat) {
            $mount = 'IPBK_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            & reg.exe load "HKU\$mount" "$dat" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                try { & $readKey ([Microsoft.Win32.Registry]::Users.OpenSubKey("$mount\$sub")) }
                finally {
                    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
                    for ($i = 0; $i -lt 5; $i++) { & reg.exe unload "HKU\$mount" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 500 }
                }
            }
        }
    }
    foreach ($f in $script:Folders) { if (-not $h.ContainsKey($f.Id)) { $h[$f.Id] = Join-Path $ProfilePath $f.Default } }
    return $h
}

function Test-IpBkSkip { param([string] $Name, [string[]] $Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}

function Measure-IpFolder {
    <#
    .SYNOPSIS
        Velikost složky bez odkazů (junction/symlink), bez souborů jen v cloudu (OneDrive) a bez vynechaných složek.
    #>
    param([Parameter(Mandatory)] [string] $Path, [string[]] $SkipDirs = @(), [string[]] $OnlyFiles = @(), [int] $MaxDepth = 64, [int] $MaxSeconds = 90)
    $size = [long]0; $files = 0; $partial = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@($Path, 0))
    # Offline + RECALL_ON_DATA_ACCESS + RECALL_ON_OPEN (soubory jen v cloudu) – jako čísla, PS 5.1 je nezná ve výčtu
    $cloud = [int][IO.FileAttributes]::Offline -bor 0x400000 -bor 0x40000
    while ($stack.Count) {
        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { $partial = $true; break }
        $cur = $stack.Pop()
        $entries = try { (New-Object IO.DirectoryInfo $cur[0]).GetFileSystemInfos() } catch { @() }
        foreach ($e in $entries) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.Attributes -band [IO.FileAttributes]::Directory) {
                if ($cur[1] + 1 -lt $MaxDepth -and -not (Test-IpBkSkip $e.Name $SkipDirs)) { $stack.Push(@($e.FullName, ($cur[1] + 1))) }
                continue
            }
            if (([int]$e.Attributes) -band $cloud) { continue }
            if ($OnlyFiles.Count -and -not (Test-IpBkSkip $e.Name $OnlyFiles)) { continue }
            if (Test-IpBkSkip $e.Name $script:FileSkip) { continue }
            $size += $e.Length; $files++
        }
    }
    return [pscustomobject]@{ Size = $size; Files = $files; Partial = $partial }
}

function Get-IpBrowserProfileNames {
    # Názvy profilů prohlížeče (Chromium: Local State, Firefox: profiles.ini) – jen pro zobrazení.
    param([Parameter(Mandatory)] $Browser, [Parameter(Mandatory)] [string] $Path)
    try {
        if ($Browser.Kind -eq 'firefox') {
            $ini = Join-Path $Path 'profiles.ini'
            if (-not (Test-Path -LiteralPath $ini)) { return @() }
            return @([IO.File]::ReadAllLines($ini) | Where-Object { $_ -match '^Name=(.+)$' } | ForEach-Object { $Matches[1] })
        }
        $ls = Join-Path $Path 'Local State'
        if (-not (Test-Path -LiteralPath $ls)) { return @() }
        $j = [IO.File]::ReadAllText($ls, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $cache = $j.profile.info_cache
        if (-not $cache) { return @() }
        return @(foreach ($p in $cache.PSObject.Properties) {
                $n = [string]$p.Value.name; $u = [string]$p.Value.user_name
                if ($u) { "$n ($u)" } elseif ($n) { $n } else { $p.Name }
            })
    } catch { return @() }
}

function Get-IpBackupItems {
    <#
    .SYNOPSIS
        Co jde u uživatele zálohovat: složky (i přesměrované) a prohlížeče, které mají data. S velikostí (bez -NoSize).
    #>
    param([Parameter(Mandatory)] [string] $Sid, [Parameter(Mandatory)] [string] $ProfilePath, [switch] $NoSize)
    $sf = Get-IpUserShellFolders -Sid $Sid -ProfilePath $ProfilePath
    $owners = Get-IpBkProcessOwners
    $run = if ($owners.ContainsKey($Sid)) { $owners[$Sid] } else { @{} }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $script:Folders) {
        $p = [string]$sf[$f.Id]
        $remote = $p.StartsWith('\\')
        $exists = Test-Path -LiteralPath $p -PathType Container
        $m = if ($exists -and -not $remote -and -not $NoSize) { Measure-IpFolder -Path $p } else { $null }
        $out.Add([pscustomobject]@{
                Id = $f.Id; Group = 'folder'; Name = $f.Name; Path = $p; Dir = $f.Dir; Exists = $exists; Remote = $remote
                OneDrive = ($p -match '\\OneDrive( - [^\\]+)?(\\|$)'); Size = $(if ($m) { $m.Size } else { [long]-1 }); Files = $(if ($m) { $m.Files } else { 0 }); Partial = [bool]($m -and $m.Partial)
                Default = $(if ($f.On -and $exists -and -not $remote) { 'on' } else { '' }); Profiles = @(); Running = $false; Kind = 'folder'; BookmarkSize = [long]-1
            })
    }
    foreach ($b in $script:Browsers) {
        $p = Join-Path $ProfilePath $b.Rel
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        $skip = if ($b.Kind -eq 'firefox') { $script:FirefoxSkip } else { $script:ChromiumSkip }
        $m = if ($NoSize) { $null } else { Measure-IpFolder -Path $p -SkipDirs $skip }
        $bm = if ($NoSize) { $null } elseif ($b.Kind -eq 'firefox') { Measure-IpFolder -Path $p -OnlyFiles @('places.sqlite', 'favicons.sqlite', '*.jsonlz4', 'profiles.ini', 'installs.ini') -MaxDepth 4 } else { Measure-IpFolder -Path $p -OnlyFiles @('Bookmarks', 'Bookmarks.bak') -MaxDepth 2 }
        $out.Add([pscustomobject]@{
                Id = $b.Id; Group = 'browser'; Name = $b.Name; Path = $p; Dir = $b.Dir; Exists = $true; Remote = $false; OneDrive = $false
                Size = $(if ($m) { $m.Size } else { [long]-1 }); Files = $(if ($m) { $m.Files } else { 0 }); Partial = [bool]($m -and $m.Partial)
                Default = 'full'; Profiles = @(Get-IpBrowserProfileNames -Browser $b -Path $p); Running = $run.ContainsKey($b.Proc); Kind = $b.Kind
                BookmarkSize = $(if ($bm) { $bm.Size } else { [long]-1 })
            })
    }
    return $out.ToArray()
}

function Get-IpRunningBrowsers {
    # Prohlížeče z $Ids, které má uživatel $Sid právě spuštěné.
    param([Parameter(Mandatory)] [string] $Sid, [string[]] $Ids = @())
    $owners = Get-IpBkProcessOwners
    if (-not $owners.ContainsKey($Sid)) { return @() }
    return @($script:Browsers | Where-Object { ($Ids.Count -eq 0 -or $Ids -contains $_.Id) -and $owners[$Sid].ContainsKey($_.Proc) })
}

function Stop-IpUserBrowsers {
    <#
    .SYNOPSIS
        Zavře prohlížeče uživatele (nejdřív slušně, po 8 s natvrdo). Otevřené soubory profilu by jinak nešly zkopírovat.
    #>
    param([Parameter(Mandatory)] [string] $Sid, [string[]] $Ids = @())
    $names = @($script:Browsers | Where-Object { $Ids.Count -eq 0 -or $Ids -contains $_.Id } | ForEach-Object { "$($_.Proc).exe" })
    if (-not $names.Count) { return 0 }
    $filter = ($names | ForEach-Object { "Name='$_'" }) -join ' OR '
    $mine = @(foreach ($p in @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
            $s = try { [string](Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid } catch { '' }
            if ($s -eq $Sid) { [int]$p.ProcessId }
        })
    foreach ($id in $mine) { try { [void](Get-Process -Id $id -ErrorAction Stop).CloseMainWindow() } catch { } }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 8 -and @($mine | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count) { Start-Sleep -Milliseconds 400 }
    foreach ($id in $mine) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { } }
    Start-Sleep -Milliseconds 800
    return $mine.Count
}

#endregion

#region Kopírování (robocopy)

function Invoke-IpRobocopy {
    <#
    .SYNOPSIS
        Spustí robocopy, průběžně hlásí zkopírované bajty a vrací kód, počet souborů a chyb.
        Kód 0–7 = v pořádku, 8+ = některé soubory nešly zkopírovat.
    #>
    param(
        [Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Dest,
        [string[]] $Files = @(), [string[]] $Options = @(), [string] $LogFile, [scriptblock] $OnProgress, $State
    )
    $q = { param([string] $s) if ($s -match '\s|&|\(|\)') { '"' + $s.TrimEnd('\') + '"' } else { $s.TrimEnd('\') } }
    $a = @((& $q $Source), (& $q $Dest)) + @($Files | ForEach-Object { & $q $_ }) + $Options + @('/R:1', '/W:1', '/NP', '/NDL', '/NJH', '/NJS', '/BYTES', '/FP', '/TEE')
    if ($LogFile) { $a += "/UNILOG+:$(& $q $LogFile)" }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $psi.Arguments = $a -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $bytes = [long]0; $count = 0; $failed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $cancelled = $false; $last = [Diagnostics.Stopwatch]::StartNew(); $file = ''
    $rxFile = [regex]'^\s*(?:[^\d\\:]*?)\s+(\d+)\s+((?:[A-Za-z]:\\|\\\\).+)$'
    $rxErr = [regex]'ERROR\s+\d+\s+\(0x[0-9A-Fa-f]+\)\s+[^\\]*?((?:[A-Za-z]:\\|\\\\).+?)\s*$'
    $pending = $p.StandardOutput.ReadLineAsync()
    while ($true) {
        if (-not $pending.Wait(400)) {
            if ($State -and $State['Cancel']) { $cancelled = $true; try { $p.Kill() } catch { }; break }
            if ($OnProgress -and $last.ElapsedMilliseconds -gt 700) { & $OnProgress $bytes $file; $last.Restart() }
            continue
        }
        $line = $pending.Result
        if ($null -eq $line) { break }
        $m = $rxErr.Match($line)
        if ($m.Success) { [void]$failed.Add($m.Groups[1].Value) }
        else {
            $m = $rxFile.Match($line)
            if ($m.Success) { $bytes += [long]$m.Groups[1].Value; $count++; $file = $m.Groups[2].Value }
        }
        if ($State -and $State['Cancel']) { $cancelled = $true; try { $p.Kill() } catch { }; break }
        if ($OnProgress -and $last.ElapsedMilliseconds -gt 700) { & $OnProgress $bytes $file; $last.Restart() }
        $pending = $p.StandardOutput.ReadLineAsync()
    }
    $p.WaitForExit()
    [void]$errTask.Wait(2000)
    if ($OnProgress) { & $OnProgress $bytes '' }
    $fa = New-Object string[] $failed.Count; $failed.CopyTo($fa)
    return [pscustomobject]@{ Code = $(if ($cancelled) { -1 } else { $p.ExitCode }); Bytes = $bytes; Files = $count; Failed = $fa; Cancelled = $cancelled }
}

function Get-IpCopyOptions {
    # Společné volby: podsložky, bez odkazů, datum a atributy, bez souborů jen v cloudu, 8 vláken.
    param([switch] $NoOverwriteNewer)
    $o = @('/E', '/XJ', '/COPY:DAT', '/DCOPY:T', '/XA:O', '/MT:8')
    if (Test-IpAdmin) { $o += '/B' }
    if ($NoOverwriteNewer) { $o += '/XO' }
    $o += '/XF'; $o += @($script:FileSkip | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
    return $o
}

function Get-IpSkipDirOptions { param([string[]] $Dirs)
    if (-not $Dirs.Count) { return @() }
    return @('/XD') + @($Dirs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } })
}

function Set-IpBackupAcl {
    # Zálohu (hesla, klíče) smí číst jen SYSTEM, správci, ten, kdo zálohuje, a vlastník dat.
    param([Parameter(Mandatory)] [string] $Path, [string[]] $Sids)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
    $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($s in @(@('S-1-5-18', 'S-1-5-32-544') + $Sids | Where-Object { $_ } | Select-Object -Unique)) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $s), 'FullControl', $inh, 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Save-IpManifest { param([string] $Dir, $Manifest)
    $tmp = Join-Path $Dir "$($script:ManifestName).tmp"
    [IO.File]::WriteAllText($tmp, ($Manifest | ConvertTo-Json -Depth 6), $script:Utf8)
    # .NET místo Move-Item: funguje i s krátkými cestami 8.3 (C:\Users\ABC~1\…) a na NAS
    $f = Join-Path $Dir $script:ManifestName
    [IO.File]::Copy($tmp, $f, $true); [IO.File]::Delete($tmp)
}

function ConvertTo-IpSafeName { param([string] $Text)
    $t = ($Text -replace '[\\/:*?"<>|\s]+', '-').Trim('-', '.')
    if (-not $t) { $t = 'uzivatel' }
    return $t
}

#endregion

#region Záloha

function Resolve-IpBackupUser {
    # Uživatel podle SID + kontrola oprávnění: bez práv správce jen vlastní účet.
    param([Parameter(Mandatory)] [string] $Sid)
    if ($Sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { throw 'Neplatný účet.' }
    $u = @(Get-IpBackupUsers | Where-Object Sid -eq $Sid)[0]
    if (-not $u) { throw 'Uživatel na tomto počítači nemá profil.' }
    if (-not (Test-IpAdmin) -and -not $u.Self) { throw 'Bez práv správce jde zálohovat a obnovit jen vlastní profil. Spusťte aplikaci jako správce (IT).' }
    return $u
}

function Invoke-IpUserBackup {
    <#
    .SYNOPSIS
        Zálohuje vybrané položky uživatele do nové složky v $Target. Spouští okno (úloha na pozadí).
    .PARAMETER Select
        @( @{ Id = 'desktop'; Mode = 'on' }, @{ Id = 'chrome'; Mode = 'full' | 'bookmarks' }, ... )  volitelně Size (bajty) pro průběh.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Sid, [Parameter(Mandatory)] [object[]] $Select,
        [Parameter(Mandatory)] [string] $Target, $Queue, $State)
    $ev = { param([hashtable] $d) Send-IpEvent -Queue $Queue -Data $d }
    $log = { param([string] $Level, [string] $Message)
        Write-IpLog -Settings $Settings -Level $Level -Message "Záloha: $Message"
        & $ev @{ Kind = 'bklog'; Level = $Level; Message = $Message } }
    $results = New-Object System.Collections.Generic.List[object]
    $dest = ''
    try {
        $u = Resolve-IpBackupUser -Sid $Sid
        $Target = $Target.Trim().TrimEnd('\')
        if (-not $Target) { throw 'Vyberte, kam zálohu uložit.' }
        if (($Target + '\').StartsWith($u.ProfilePath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Zálohu nejde uložit do profilu, který se zálohuje.' }
        $items = @(Get-IpBackupItems -Sid $Sid -ProfilePath $u.ProfilePath -NoSize)
        $plan = New-Object System.Collections.Generic.List[object]
        foreach ($s in $Select) {
            $id = [string](Get-IpValue $s 'Id' ''); $mode = [string](Get-IpValue $s 'Mode' '')
            $it = @($items | Where-Object Id -eq $id)[0]
            if (-not $it -or -not $mode) { continue }
            if ($it.Group -eq 'browser' -and $mode -notin @('full', 'bookmarks')) { continue }
            $plan.Add([pscustomobject]@{ Item = $it; Mode = $(if ($it.Group -eq 'folder') { 'on' } else { $mode }); Size = [long](Get-IpValue $s 'Size' -1) })
        }
        if (-not $plan.Count) { throw 'Není vybráno nic k zálohování.' }
        $needDpapi = @($plan | Where-Object { $_.Item.Kind -eq 'chromium' -and $_.Mode -eq 'full' }).Count -gt 0

        if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null; & $log 'Info' "Založena složka $Target." }
        $dest = Join-Path $Target ('{0}_{1}_{2:yyyyMMdd-HHmm}' -f [Environment]::MachineName, (ConvertTo-IpSafeName $u.Short), (Get-Date))
        if (Test-Path -LiteralPath $dest) { $dest += '-' + [guid]::NewGuid().ToString('N').Substring(0, 4) }
        New-Item -ItemType Directory -Path $dest | Out-Null
        $logFile = Join-Path $dest '_robocopy.log'
        $os = try { $c = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; "$($c.Caption) $($c.Version)" } catch { [Environment]::OSVersion.VersionString }
        $man = [ordered]@{
            Version = 1; Tool = "Instalace programů $(Get-IpVersion)"; Computer = [Environment]::MachineName; Os = $os
            User = $u.Name; Short = $u.Short; Sid = $u.Sid; Kind = $u.Kind; ProfilePath = $u.ProfilePath
            Created = (Get-Date).ToString('s'); Finished = ''; By = "$([Environment]::UserDomainName)\$([Environment]::UserName)"; State = 'running'; Items = @()
        }
        Save-IpManifest -Dir $dest -Manifest $man
        & $log 'Info' "Zálohuji $($u.Name) do $dest"
        & $ev @{ Kind = 'bkstart'; Path = $dest }

        $total = [long]0; foreach ($x in $plan) { if ($x.Size -gt 0) { $total += $x.Size } }
        $doneBytes = [long]0
        $manItems = New-Object System.Collections.Generic.List[object]
        $steps = $plan.ToArray() + $(if ($needDpapi) { , [pscustomobject]@{ Item = $script:Dpapi; Mode = 'on'; Size = [long]-1 } } else { @() })
        foreach ($x in $steps) {
            if ($State -and $State['Cancel']) { break }
            $it = $x.Item; $id = $it.Id
            $src = if ($id -eq 'dpapi') { Join-Path $u.ProfilePath $script:Dpapi.Rel } else { $it.Path }
            $dst = Join-Path $dest $it.Dir
            $name = $it.Name + $(if ($x.Mode -eq 'bookmarks') { ' – jen záložky' } elseif ($it.Group -eq 'browser') { ' – celý profil' } else { '' })
            $r = [ordered]@{ Id = $id; Name = $it.Name; Group = $(if ($id -eq 'dpapi') { 'dpapi' } else { $it.Group }); Mode = $x.Mode; Source = $src; Dir = $it.Dir; Size = [long]0; Files = 0; Result = ''; Message = '' }
            try {
                if (-not (Test-Path -LiteralPath $src)) { throw "složka neexistuje ($src)" }
                if ($it.Group -eq 'folder' -and $it.Remote) { throw 'složka je přesměrovaná na server – data už jsou zálohovaná tam' }
                if ($it.Group -eq 'browser' -and @(Get-IpRunningBrowsers -Sid $Sid -Ids @($id)).Count) { & $log 'Warning' "$($it.Name) je spuštěný – otevřené soubory (hesla, historie) nemusí jít zkopírovat. Zavřete ho." }
                & $ev @{ Kind = 'bkitem'; Id = $id; State = 'run'; Message = $name }
                & $log 'Info' "$name  ($src)"
                $opt = Get-IpCopyOptions
                $files = @()
                if ($it.Group -eq 'browser' -and $x.Mode -eq 'bookmarks') {
                    $opt = @($opt | Where-Object { $_ -ne '/E' }) + @('/S')
                    if ($it.Kind -eq 'firefox') { $files = @('places.sqlite', 'favicons.sqlite', '*.jsonlz4', 'profiles.ini', 'installs.ini'); $opt += '/LEV:4' }
                    else { $files = @('Bookmarks', 'Bookmarks.bak'); $opt += '/LEV:2' }
                }
                elseif ($it.Kind -eq 'chromium') { $opt += Get-IpSkipDirOptions $script:ChromiumSkip }
                elseif ($it.Kind -eq 'firefox') { $opt += Get-IpSkipDirOptions $script:FirefoxSkip }
                $base = $doneBytes; $sz = $x.Size
                # volá se synchronně z Invoke-IpRobocopy – proměnné ($id, $base…) najde v této funkci
                $onp = { param([long] $b, [string] $f) & $ev @{ Kind = 'bkprog'; Id = $id; Name = $name; Done = ($base + $b); Total = $total; ItemDone = $b; ItemTotal = $sz; File = $f } }
                $rc = Invoke-IpRobocopy -Source $src -Dest $dst -Files $files -Options $opt -LogFile $logFile -OnProgress $onp -State $State
                $doneBytes += [Math]::Max($rc.Bytes, [Math]::Max(0, $x.Size))
                $r.Size = $rc.Bytes; $r.Files = $rc.Files
                if ($rc.Cancelled) { $r.Result = 'cancel'; $r.Message = 'zastaveno' }
                elseif ($rc.Code -ge 16) { throw "robocopy skončil chybou $($rc.Code) – viz _robocopy.log v záloze" }
                elseif ($rc.Code -ge 8 -or $rc.Failed.Count) {
                    $r.Result = 'warn'
                    $r.Message = "$(Format-IpSize $rc.Bytes), $($rc.Files) souborů · $($rc.Failed.Count) nešlo zkopírovat (otevřené nebo bez oprávnění), např. $([IO.Path]::GetFileName(@($rc.Failed)[0]))"
                }
                elseif ($x.Mode -eq 'bookmarks' -and $rc.Files -eq 0) { $r.Result = 'warn'; $r.Message = 'prohlížeč nemá uložené žádné záložky (soubor Bookmarks / places.sqlite nenalezen)' }
                else { $r.Result = 'ok'; $r.Message = "$(Format-IpSize $rc.Bytes), $($rc.Files) souborů" }
                if ($id -eq 'dpapi' -and $r.Result -ne 'cancel') { $r.Message += ' · hesla Chrome/Edge půjdou po obnově přečíst stejným účtem' }
            }
            catch { $r.Result = 'err'; $r.Message = $_.Exception.Message }
            $lv = @{ ok = 'Success'; warn = 'Warning'; err = 'Error'; cancel = 'Warning' }[$r.Result]
            & $log $lv "$name – $($r.Message)"
            & $ev @{ Kind = 'bkitem'; Id = $id; State = $r.Result; Message = $r.Message }
            $manItems.Add([pscustomobject]$r); $results.Add([pscustomobject]$r)
            $man.Items = $manItems.ToArray(); Save-IpManifest -Dir $dest -Manifest $man
        }
        $man.Finished = (Get-Date).ToString('s')
        $man.State = if ($State -and $State['Cancel']) { 'cancelled' } elseif (@($results | Where-Object Result -eq 'err').Count) { 'errors' } elseif (@($results | Where-Object Result -eq 'warn').Count) { 'warnings' } else { 'ok' }
        Save-IpManifest -Dir $dest -Manifest $man
        try {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Set-IpBackupAcl -Path $dest -Sids @($me, $u.Sid)
            & $log 'Info' 'Přístup k záloze omezen na správce, vás a vlastníka dat (záloha obsahuje hesla).'
        }
        catch { & $log 'Warning' "Oprávnění zálohy nejde omezit ($($_.Exception.Message)) – složka má práva podle nadřazené složky. Záloha obsahuje hesla, uložte ji jen tam, kam má přístup IT." }
        $sum = [long]0; foreach ($x in $results) { $sum += [long]$x.Size }
        & $log $(if ($man.State -eq 'ok') { 'Success' } else { 'Warning' }) "Záloha dokončena: $(Format-IpSize $sum) · $dest"
    }
    catch { & $log 'Error' $_.Exception.Message; $results.Add([pscustomobject]@{ Id = ''; Name = 'Záloha'; Result = 'err'; Message = $_.Exception.Message }) }
    & $ev @{ Kind = 'bkdone'; Op = 'backup'; Path = $dest; Results = $results.ToArray() }
}

#endregion

#region Seznam záloh a obnova

function Read-IpBackupManifest {
    param([Parameter(Mandatory)] [string] $Path)
    $f = Join-Path $Path $script:ManifestName
    if (-not (Test-Path -LiteralPath $f)) { throw "Ve složce není záloha ($script:ManifestName): $Path" }
    $j = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $size = [long]0; foreach ($i in @($j.Items)) { $size += [long](Get-IpValue $i 'Size' 0) }
    return [pscustomobject]@{
        Path = $Path; Computer = [string]$j.Computer; User = [string]$j.User; Short = [string]$j.Short; Sid = [string]$j.Sid; Os = [string]$j.Os
        Created = $(try { [datetime]::Parse([string]$j.Created) } catch { $null }); State = [string]$j.State; By = [string]$j.By; Size = $size
        Items = @($j.Items | Where-Object { $_ -and [string]$_.Result -in @('ok', 'warn') })
    }
}

function Get-IpBackups {
    # Zálohy ve složce $Root (podsložky s backup.json), nejnovější první.
    param([Parameter(Mandatory)] [string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $out = foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 300)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName $script:ManifestName))) { continue }
        try { Read-IpBackupManifest -Path $d.FullName } catch { }
    }
    return @($out | Sort-Object @{ Expression = { $_.Created }; Descending = $true })
}

function Get-IpFirefoxDefaultProfile {
    # Výchozí profil Firefoxu (installs.ini / profiles.ini) – plná cesta, nebo ''.
    param([Parameter(Mandatory)] [string] $Root)
    $rel = ''
    foreach ($ini in 'installs.ini', 'profiles.ini') {
        $f = Join-Path $Root $ini
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = [IO.File]::ReadAllLines($f)
        if ($ini -eq 'installs.ini') { $l = @($lines | Where-Object { $_ -match '^Default=(.+)$' })[0]; if ($l -and $l -match '^Default=(.+)$') { $rel = $Matches[1] } }
        else {
            $sec = @{}; $cur = $null
            foreach ($l in $lines) {
                if ($l -match '^\[(.+)\]$') { $cur = @{}; $sec[$Matches[1]] = $cur; continue }
                if ($cur -ne $null -and $l -match '^([^=]+)=(.*)$') { $cur[$Matches[1]] = $Matches[2] }
            }
            $p = @($sec.Values | Where-Object { $_['Default'] -eq '1' -and $_['Path'] })[0]
            if (-not $p) { $p = @($sec.Values | Where-Object { $_['Path'] })[0] }
            if ($p) { $rel = $p['Path'] }
        }
        if ($rel) { break }
    }
    if (-not $rel) { return '' }
    $full = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $Root ($rel -replace '/', '\') }
    if (Test-Path -LiteralPath $full) { return $full }
    return ''
}

function Rename-IpAside {
    # Stávající soubor / složku odloží vedle sebe (*.pred-obnovou-<datum>). Vrací nový název, nebo ''.
    param([Parameter(Mandatory)] [string] $Path)
    $new = '{0}.pred-obnovou-{1:yyyyMMdd-HHmmss}' -f [IO.Path]::GetFileName($Path.TrimEnd('\')), (Get-Date)
    $to = Join-Path ([IO.Path]::GetDirectoryName($Path.TrimEnd('\'))) $new
    if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Move($Path, $to); return $new }
    if ([IO.File]::Exists($Path)) { [IO.File]::Move($Path, $to); return $new }
    return ''
}

function Invoke-IpUserRestore {
    <#
    .SYNOPSIS
        Obnoví položky ze zálohy $BackupPath do profilu uživatele $Sid na tomto PC.
    .PARAMETER Ids
        ID položek ze zálohy (desktop, documents, downloads, pictures, chrome, edge, brave, opera, firefox).
        Klíče DPAPI se obnoví samy, když se obnovuje celý profil Chromium prohlížeče a jde o stejný účet.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $BackupPath, [Parameter(Mandatory)] [string] $Sid,
        [Parameter(Mandatory)] [string[]] $Ids, $Queue, $State)
    $ev = { param([hashtable] $d) Send-IpEvent -Queue $Queue -Data $d }
    $log = { param([string] $Level, [string] $Message)
        Write-IpLog -Settings $Settings -Level $Level -Message "Obnova: $Message"
        & $ev @{ Kind = 'bklog'; Level = $Level; Message = $Message } }
    $results = New-Object System.Collections.Generic.List[object]
    try {
        $u = Resolve-IpBackupUser -Sid $Sid
        $bk = Read-IpBackupManifest -Path $BackupPath
        $logFile = Join-Path ([IO.Path]::GetTempPath()) ('InstalaceProgramu-obnova-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
        $sameAccount = $bk.Sid -eq $u.Sid
        & $log 'Info' "Obnovuji zálohu $($bk.User) z $($bk.Computer) ($(if ($bk.Created) { $bk.Created.ToString('d. M. yyyy H:mm') })) do profilu $($u.Name)"
        $targets = @(Get-IpBackupItems -Sid $u.Sid -ProfilePath $u.ProfilePath -NoSize)
        $known = @{}; foreach ($f in $script:Folders) { $known[$f.Id] = $f }; foreach ($b in $script:Browsers) { $known[$b.Id] = $b }
        $sel = @($bk.Items | Where-Object { $Ids -contains [string]$_.Id -and $known.ContainsKey([string]$_.Id) })
        if (-not $sel.Count) { throw 'Není vybráno nic k obnovení.' }
        $total = [long]0; foreach ($x in $sel) { $total += [long](Get-IpValue $x 'Size' 0) }
        $doneBytes = [long]0
        $steps = @($sel)
        $dp = @($bk.Items | Where-Object { [string]$_.Id -eq 'dpapi' })[0]
        $chromiumFull = @($sel | Where-Object { $known[[string]$_.Id].PSObject.Properties['Kind'] -and $known[[string]$_.Id].Kind -eq 'chromium' -and [string]$_.Mode -eq 'full' }).Count
        if ($chromiumFull -and $dp) { $steps += $dp }
        foreach ($x in $steps) {
            if ($State -and $State['Cancel']) { break }
            $id = [string]$x.Id; $mode = [string](Get-IpValue $x 'Mode' 'on')
            $def = if ($id -eq 'dpapi') { $script:Dpapi } else { $known[$id] }
            # cesta v záloze jen z vlastního seznamu (ne z backup.json)
            $src = Join-Path $BackupPath $def.Dir
            $r = [ordered]@{ Id = $id; Name = $def.Name; Result = ''; Message = ''; Size = [long]0 }
            try {
                if (-not (Test-Path -LiteralPath $src)) { throw "v záloze chybí složka $($def.Dir)" }
                $sz = [long](Get-IpValue $x 'Size' -1)
                $base = $doneBytes
                $onp = { param([long] $b, [string] $f) & $ev @{ Kind = 'bkprog'; Id = $id; Name = $def.Name; Done = ($base + $b); Total = $total; ItemDone = $b; ItemTotal = $sz; File = $f } }
                & $ev @{ Kind = 'bkitem'; Id = $id; State = 'run'; Message = $def.Name }
                $note = ''
                if ($id -eq 'dpapi') {
                    if (-not $sameAccount) { throw 'jiný účet než v záloze – klíče DPAPI patří jen původnímu účtu' }
                    $dst = Join-Path $u.ProfilePath $script:Dpapi.Rel
                    # nikdy nepřepsat stávající klíče (ani soubor Preferred) – jen doplnit staré
                    $opt = @(Get-IpCopyOptions) + @('/XC', '/XN', '/XO')
                    $rc = Invoke-IpRobocopy -Source $src -Dest $dst -Options $opt -LogFile $logFile -State $State
                    $note = 'staré klíče doplněny, hesla Chrome/Edge půjdou přečíst'
                }
                elseif ($def.PSObject.Properties['Reg']) {
                    $t = @($targets | Where-Object Id -eq $id)[0]
                    $dst = if ($t) { $t.Path } else { Join-Path $u.ProfilePath $def.Default }
                    if ($dst.StartsWith('\\')) { $note = 'složka uživatele je přesměrovaná na server' }
                    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
                    $rc = Invoke-IpRobocopy -Source $src -Dest $dst -Options (Get-IpCopyOptions -NoOverwriteNewer) -LogFile $logFile -OnProgress $onp -State $State
                    $note = (@($note, "do $dst") | Where-Object { $_ }) -join ' · '
                }
                else {
                    if (@(Get-IpRunningBrowsers -Sid $u.Sid -Ids @($id)).Count) { throw "$($def.Name) je u uživatele spuštěný – zavřete ho a obnovte znovu" }
                    $dst = Join-Path $u.ProfilePath $def.Rel
                    if ($mode -eq 'full') {
                        $aside = Rename-IpAside -Path $dst
                        if ($aside) { $note = "původní profil odložen jako $aside" }
                        New-Item -ItemType Directory -Path $dst -Force | Out-Null
                        $rc = Invoke-IpRobocopy -Source $src -Dest $dst -Options (Get-IpCopyOptions) -LogFile $logFile -OnProgress $onp -State $State
                        if ($def.Kind -eq 'chromium' -and -not $sameAccount) { $note = (@($note, 'jiný účet než v záloze – uložená hesla nepůjdou přečíst (přeneste je synchronizací nebo exportem CSV)') | Where-Object { $_ }) -join ' · ' }
                        elseif ($def.Kind -eq 'chromium' -and -not $dp) { $note = (@($note, 'v záloze chybí klíče DPAPI – uložená hesla nemusí jít přečíst') | Where-Object { $_ }) -join ' · ' }
                    }
                    elseif ($def.Kind -eq 'firefox') {
                        $tp = if (Test-Path -LiteralPath $dst) { Get-IpFirefoxDefaultProfile -Root $dst } else { '' }
                        if (-not $tp) {
                            # Firefox tu ještě nebyl: stačí nakopírovat záložky i se seznamem profilů
                            New-Item -ItemType Directory -Path $dst -Force | Out-Null
                            $rc = Invoke-IpRobocopy -Source $src -Dest $dst -Options (Get-IpCopyOptions) -LogFile $logFile -OnProgress $onp -State $State
                        }
                        else {
                            $sp = Get-IpFirefoxDefaultProfile -Root $src
                            if (-not $sp) { $sp = @(Get-ChildItem -LiteralPath $src -Recurse -Filter 'places.sqlite' -File | Sort-Object Length -Descending | Select-Object -First 1 | ForEach-Object { $_.DirectoryName })[0] }
                            if (-not $sp) { throw 'v záloze nejsou záložky Firefoxu (places.sqlite)' }
                            foreach ($n in 'places.sqlite', 'places.sqlite-wal', 'favicons.sqlite', 'favicons.sqlite-wal') { [void](Rename-IpAside -Path (Join-Path $tp $n)) }
                            $rc = Invoke-IpRobocopy -Source $sp -Dest $tp -Files @('places.sqlite', 'favicons.sqlite') -Options @('/COPY:DAT', '/XJ') -LogFile $logFile -OnProgress $onp -State $State
                            if (Test-Path -LiteralPath (Join-Path $sp 'bookmarkbackups')) { [void](Invoke-IpRobocopy -Source (Join-Path $sp 'bookmarkbackups') -Dest (Join-Path $tp 'bookmarkbackups') -Options @('/E', '/COPY:DAT', '/XO') -LogFile $logFile -State $State) }
                            $note = "do profilu $(Split-Path -Leaf $tp) (původní záložky a historie odloženy)"
                        }
                    }
                    else {
                        # Chromium – jen soubory Bookmarks do odpovídajících profilů. Local State se NEkopíruje (klíč k heslům na tomto PC).
                        $n = 0
                        foreach ($bf in @(Get-ChildItem -LiteralPath $src -Recurse -Filter 'Bookmarks' -File -ErrorAction SilentlyContinue)) {
                            $rel = $bf.DirectoryName.Substring($src.TrimEnd('\').Length).TrimStart('\')
                            $td = if ($rel) { Join-Path $dst $rel } else { $dst }
                            if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }
                            [void](Rename-IpAside -Path (Join-Path $td 'Bookmarks'))
                            [IO.File]::Copy($bf.FullName, (Join-Path $td 'Bookmarks'), $true)
                            $n++; $r.Size += $bf.Length
                        }
                        if (-not $n) { throw 'v záloze nejsou záložky (soubor Bookmarks)' }
                        $rc = [pscustomobject]@{ Code = 1; Bytes = $r.Size; Files = $n; Failed = @(); Cancelled = $false }
                        $note = "záložky v $n $(if ($n -eq 1) { 'profilu' } else { 'profilech' }) (původní odloženy)"
                    }
                }
                $doneBytes += [Math]::Max($rc.Bytes, [Math]::Max(0, $sz))
                $r.Size = $rc.Bytes
                if ($rc.Cancelled) { $r.Result = 'cancel'; $r.Message = 'zastaveno' }
                elseif ($rc.Code -ge 16) { throw "robocopy skončil chybou $($rc.Code) – log: $logFile" }
                elseif ($rc.Code -ge 8 -or $rc.Failed.Count) { $r.Result = 'warn'; $r.Message = "$(Format-IpSize $rc.Bytes) · $($rc.Failed.Count) souborů nešlo zapsat (log: $logFile)" }
                elseif ($rc.Files -eq 0) { $r.Result = 'ok'; $r.Message = 'vše už je na tomto PC (stejné nebo novější soubory)' }
                else { $r.Result = 'ok'; $r.Message = "$(Format-IpSize $rc.Bytes), $($rc.Files) souborů" }
                if ($note) { $r.Message += " · $note" }
                if ($r.Result -eq 'ok' -and $note -match 'nepůjdou|nemusí') { $r.Result = 'warn' }
            }
            catch { $r.Result = 'err'; $r.Message = $_.Exception.Message }
            $lv = @{ ok = 'Success'; warn = 'Warning'; err = 'Error'; cancel = 'Warning' }[$r.Result]
            & $log $lv "$($def.Name) – $($r.Message)"
            & $ev @{ Kind = 'bkitem'; Id = $id; State = $r.Result; Message = $r.Message }
            $results.Add([pscustomobject]$r)
        }
        & $log 'Info' "Obnova dokončena. Log kopírování: $logFile"
    }
    catch { & $log 'Error' $_.Exception.Message; $results.Add([pscustomobject]@{ Id = ''; Name = 'Obnova'; Result = 'err'; Message = $_.Exception.Message }) }
    & $ev @{ Kind = 'bkdone'; Op = 'restore'; Path = $BackupPath; Results = $results.ToArray() }
}

#endregion

function Format-IpSize { param([long] $Bytes)
    if ($Bytes -lt 0) { return '?' }
    if ($Bytes -ge 1GB) { return ('{0:0.0} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:0} kB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

Export-ModuleMember -Function @(
    'Get-IpBackupUsers', 'Get-IpUserShellFolders', 'Get-IpBackupItems', 'Measure-IpFolder', 'Get-IpRunningBrowsers', 'Stop-IpUserBrowsers',
    'Invoke-IpUserBackup', 'Read-IpBackupManifest', 'Get-IpBackups', 'Invoke-IpUserRestore', 'Format-IpSize'
)
