#Requires -Version 5.1
<#
.SYNOPSIS
    Jazyk a region uživatelů: seznam uživatelů PC (doménový / místní), přiřazení jazyka,
    nastavení klávesnice, jazyka Windows a formátů, jazykové balíčky, jazyk instalací.
.DESCRIPTION
    Přiřazení:  %ProgramData%\InstalaceProgramu\Language\assignments.json  (zapisuje jen správce / SYSTEM,
                uživatelé smí číst). Klíč = SID uživatele, nebo "default" = noví uživatelé.
    Provedení:  tools\Apply-UserLanguage.ps1 POD UŽIVATELEM – hned (je-li přihlášený) a při každém
                přihlášení (úloha InstalaceProgramu-Jazyk, skupina Uživatelé). Každé přiřazení
                se použije jednou, pak si jazyk uživatel může změnit sám.
    Instalace:  jazyk přiřazený uživateli se předává do winget (--locale) a do konfigurace Office.
.NOTES
    Pozor: v řetězcích v uvozovkách "" nepoužívat české „“ – PowerShell je bere jako konec řetězce.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

$script:Utf8 = New-Object Text.UTF8Encoding($false)
$script:LangTaskName = 'InstalaceProgramu-Jazyk'
$script:AllParts = @('keyboard', 'ui', 'region')

#region Konfigurace a přiřazení

function Read-IpLanguages {
    # config\languages.json -> seznam jazyků firmy, návrhy podle země z AD, doplňkové jazyky.
    param([Parameter(Mandatory)] $Settings)
    $j = Read-IpJson -Path $Settings.LanguagesPath
    $items = @(foreach ($l in @(Get-IpValue $j 'languages' @())) {
            $id = [string](Get-IpValue $l 'id' '')
            if ($id -notmatch '^[a-zA-Z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$') { continue }
            [pscustomobject]@{
                Id           = $id
                Name         = [string](Get-IpValue $l 'name' $id)
                Ui           = [string](Get-IpValue $l 'ui' $id)
                Culture      = [string](Get-IpValue $l 'culture' $id)
                GeoId        = [int](Get-IpValue $l 'geoId' 0)
                Keyboards    = @(@(Get-IpValue $l 'keyboards' @()) | Where-Object { [string]$_ -match '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$' } | ForEach-Object { ([string]$_).ToUpperInvariant() })
                SystemLocale = [string](Get-IpValue $l 'systemLocale' $id)
                TimeZone     = [string](Get-IpValue $l 'timeZone' '')
            }
        })
    $byId = @{}; foreach ($i in $items) { $byId[$i.Id] = $i }
    $regions = @{}
    $r = Get-IpValue $j 'regions' $null
    if ($r) { foreach ($p in $r.PSObject.Properties) { if ($byId.ContainsKey([string]$p.Value)) { $regions[$p.Name.ToUpperInvariant()] = $byId[[string]$p.Value].Id } } }
    $def = [string](Get-IpValue $j 'defaultLanguage' '')
    return [pscustomobject]@{
        Items            = $items
        ById             = $byId
        Regions          = $regions
        Default          = $(if ($byId.ContainsKey($def)) { $byId[$def].Id } else { '' })
        Secondary        = @(@(Get-IpValue $j 'secondaryLanguages' @()) | Where-Object { $byId.ContainsKey([string]$_) } | ForEach-Object { $byId[[string]$_].Id })
        LanguagePackRoot = [Environment]::ExpandEnvironmentVariables([string](Get-IpValue $j 'languagePackRoot' '')).TrimEnd('\')
    }
}

function Get-IpLanguagePaths {
    param([Parameter(Mandatory)] $Settings)
    $d = Join-Path $Settings.SystemDataDirectory 'Language'
    return @{ Dir = $d; Assign = (Join-Path $d 'assignments.json'); Script = (Join-Path $d 'Apply-UserLanguage.ps1') }
}

function Read-IpLanguageAssignments {
    # SID (nebo 'default') -> přiřazení. Číst smí každý (okno běží i pod běžným uživatelem).
    param([Parameter(Mandatory)] $Settings)
    $h = @{}
    $p = (Get-IpLanguagePaths $Settings).Assign
    if (-not (Test-Path -LiteralPath $p)) { return $h }
    try { $j = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $h }
    if ($j -and $j.Users) { foreach ($x in $j.Users.PSObject.Properties) { $h[$x.Name] = $x.Value } }
    return $h
}

function Save-IpLanguageAssignments {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [hashtable] $Map)
    if (-not (Test-IpAdmin)) { throw 'Přiřazení jazyka smí uložit jen správce nebo systémová úloha.' }
    $paths = Get-IpLanguagePaths $Settings
    [void](Initialize-IpSecureDirectory -Path $paths.Dir)
    $users = [ordered]@{}; foreach ($k in @($Map.Keys | Sort-Object)) { $users[$k] = $Map[$k] }
    $o = [ordered]@{ Version = 1; Updated = (Get-Date).ToString('s'); Computer = [Environment]::MachineName; Users = $users }
    $tmp = "$($paths.Assign).tmp"
    [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 6), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $paths.Assign -Force
}

function Get-IpInstallLanguage {
    # Jazyk pro instalace programů (winget --locale, Office): jazyk Windows přiřazený uživateli, jinak ''.
    param([hashtable] $Map, [string] $Sid)
    if (-not $Map -or -not $Sid -or -not $Map.ContainsKey($Sid)) { return '' }
    return [string]$Map[$Sid].Ui
}

function New-IpLanguageAssignment {
    param([Parameter(Mandatory)] $Languages, [Parameter(Mandatory)] [string] $Id, [string[]] $Parts, [string] $Account)
    $l = $Languages.ById[$Id]
    if (-not $l) { throw "Jazyk '$Id' není v config\languages.json." }
    $sec = @(foreach ($s in $Languages.Secondary) {
            $x = $Languages.ById[$s]
            if ($x.Culture -ne $l.Culture) { [ordered]@{ Culture = $x.Culture; Keyboards = @($x.Keyboards) } }
        })
    $p = @($Parts | Where-Object { $script:AllParts -contains $_ })
    if (-not $p.Count) { $p = $script:AllParts }
    return [pscustomobject][ordered]@{
        Language = $l.Id; Name = $l.Name; Ui = $l.Ui; Culture = $l.Culture; GeoId = $l.GeoId; Keyboards = @($l.Keyboards); Secondary = $sec
        Parts = $p; Account = $Account; Stamp = [guid]::NewGuid().ToString('N'); SetAt = (Get-Date).ToString('s')
        SetBy = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
    }
}

#endregion

#region Počítač a uživatelé

function Get-IpUiLanguages {
    # Nainstalované jazyky Windows (jazykové balíčky).
    return @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages' -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName })
}

function Get-IpMachineLanguageInfo {
    $cs = try { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { $null }
    return [pscustomobject]@{
        Computer           = [Environment]::MachineName
        PartOfDomain       = [bool]($cs -and $cs.PartOfDomain)
        Domain             = $(if ($cs) { [string]$cs.Domain } else { '' })
        SystemLocale       = $(try { (Get-WinSystemLocale).Name } catch { '' })
        TimeZone           = $(try { (Get-TimeZone).Id } catch { '' })
        UiLanguages        = @(Get-IpUiLanguages)
        CanInstallLanguage = [bool](Get-Command Install-Language -ErrorAction SilentlyContinue)
    }
}

function Get-IpMachineSid {
    # SID počítače (část SID místních účtů) – podle něj se pozná místní vs. doménový účet.
    try { $u = @(Get-LocalUser -ErrorAction Stop)[0]; if ($u) { return $u.SID.AccountDomainSid.Value } } catch { }
    try {
        $u = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop)[0]
        return (New-Object Security.Principal.SecurityIdentifier $u.SID).AccountDomainSid.Value
    } catch { return '' }
}

function Get-IpLoggedOnSids {
    # Kdo je teď přihlášený (vlastníci explorer.exe, i přes rychlé přepínání uživatelů).
    $h = @{}
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            try { $s = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid; if ($s) { $h[[string]$s] = $true } } catch { }
        }
    } catch { }
    return $h
}

function Get-IpHiveLanguage {
    # Aktuální jazyk uživatele z načteného registru (jen když je přihlášený / profil načtený).
    param([string] $Sid)
    $root = "Registry::HKEY_USERS\$Sid"
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $intl = Get-ItemProperty -LiteralPath "$root\Control Panel\International" -ErrorAction SilentlyContinue
    $desk = Get-ItemProperty -LiteralPath "$root\Control Panel\Desktop" -ErrorAction SilentlyContinue
    $prof = Get-ItemProperty -LiteralPath "$root\Control Panel\International\User Profile" -ErrorAction SilentlyContinue
    $mark = Get-ItemProperty -LiteralPath "$root\Software\InstalaceProgramu\Language" -ErrorAction SilentlyContinue
    $ui = if ($desk -and $desk.PSObject.Properties['PreferredUILanguages']) { @($desk.PreferredUILanguages)[0] } else { '' }
    return [pscustomobject]@{
        Ui        = [string]$ui
        Culture   = $(if ($intl -and $intl.PSObject.Properties['LocaleName']) { [string]$intl.LocaleName } else { '' })
        Languages = $(if ($prof -and $prof.PSObject.Properties['Languages']) { @($prof.Languages) } else { @() })
        Stamp     = $(if ($mark -and $mark.PSObject.Properties['Stamp']) { [string]$mark.Stamp } else { '' })
        AppliedAt = $(if ($mark -and $mark.PSObject.Properties['AppliedAt']) { [string]$mark.AppliedAt } else { '' })
        Result    = $(if ($mark -and $mark.PSObject.Properties['Result']) { [string]$mark.Result } else { '' })
    }
}

function ConvertTo-IpLdapValue {
    # Escapování hodnoty do LDAP filtru (RFC 4515).
    param([string] $Text)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) { '\' { [void]$sb.Append('\5c') } '*' { [void]$sb.Append('\2a') } '(' { [void]$sb.Append('\28') } ')' { [void]$sb.Append('\29') } ([char]0) { [void]$sb.Append('\00') } default { [void]$sb.Append($ch) } }
    }
    return $sb.ToString()
}

function New-IpAdSearcher {
    param([string] $Filter, [int] $Size = 50)
    $root = [adsi]'LDAP://RootDSE'
    $nc = [string]$root.defaultNamingContext
    if (-not $nc) { throw 'Doména (Active Directory) není dostupná.' }
    $ds = New-Object DirectoryServices.DirectorySearcher([adsi]"LDAP://$nc")
    $ds.Filter = $Filter; $ds.SizeLimit = $Size; $ds.PageSize = 0
    $ds.ClientTimeout = [TimeSpan]::FromSeconds(8); $ds.ServerTimeLimit = [TimeSpan]::FromSeconds(8)
    foreach ($a in 'objectSid', 'sAMAccountName', 'displayName', 'c', 'co', 'preferredLanguage', 'department', 'l', 'userPrincipalName') { [void]$ds.PropertiesToLoad.Add($a) }
    return $ds
}

function ConvertFrom-IpAdResult {
    param($R)
    $p = $R.Properties
    $one = { param($n) if ($p[$n] -and $p[$n].Count) { [string]$p[$n][0] } else { '' } }
    $sid = if ($p['objectsid'] -and $p['objectsid'].Count) { (New-Object Security.Principal.SecurityIdentifier([byte[]]$p['objectsid'][0], 0)).Value } else { '' }
    return [pscustomobject]@{
        Sid = $sid; Sam = (& $one 'samaccountname'); DisplayName = (& $one 'displayname'); Country = (& $one 'c').ToUpperInvariant(); CountryName = (& $one 'co')
        PreferredLanguage = (& $one 'preferredlanguage'); Department = (& $one 'department'); City = (& $one 'l'); Upn = (& $one 'userprincipalname')
    }
}

function Get-IpAdUserInfo {
    # Doplňující údaje z AD pro doménové účty (jméno, země, preferovaný jazyk). Bez AD vrátí prázdno.
    param([string[]] $Sids)
    $h = @{}
    $Sids = @($Sids | Where-Object { $_ })
    if (-not $Sids.Count) { return $h }
    try {
        for ($i = 0; $i -lt $Sids.Count; $i += 40) {
            $chunk = $Sids[$i..([Math]::Min($i + 39, $Sids.Count - 1))]
            $or = ($chunk | ForEach-Object {
                    $so = New-Object Security.Principal.SecurityIdentifier $_
                    $b = New-Object byte[] $so.BinaryLength; $so.GetBinaryForm($b, 0)
                    '(objectSid=' + (($b | ForEach-Object { '\{0:x2}' -f $_ }) -join '') + ')'
                }) -join ''
            $ds = New-IpAdSearcher -Filter "(&(objectCategory=person)(objectClass=user)(|$or))" -Size 100
            foreach ($r in $ds.FindAll()) { $x = ConvertFrom-IpAdResult $r; if ($x.Sid) { $h[$x.Sid] = $x } }
        }
    } catch { }
    return $h
}

function Get-IpSuggestedLanguage {
    # Návrh jazyka: preferovaný jazyk z AD, jinak podle země z AD (regions v languages.json).
    param($Languages, $Ad)
    if (-not $Ad) { return $null }
    $pl = [string]$Ad.PreferredLanguage
    if ($pl) {
        $hit = @($Languages.Items | Where-Object { $_.Id -eq $pl -or $_.Culture -eq $pl }) + @($Languages.Items | Where-Object { $_.Id -like "$($pl.Split('-')[0])-*" }) | Select-Object -First 1
        if ($hit) { return [pscustomobject]@{ Id = $hit.Id; Why = "preferovaný jazyk v AD: $pl" } }
    }
    if ($Ad.Country -and $Languages.Regions.ContainsKey($Ad.Country)) {
        $c = if ($Ad.CountryName) { "$($Ad.CountryName) ($($Ad.Country))" } else { $Ad.Country }
        return [pscustomobject]@{ Id = $Languages.Regions[$Ad.Country]; Why = "země v AD: $c" }
    }
    return $null
}

function Get-IpUserProfiles {
    <#
    .SYNOPSIS
        Uživatelé s profilem na tomto PC: doménový / místní / Entra ID, přihlášený, aktuální jazyk,
        přiřazení a návrh jazyka z AD.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Languages)
    $machineSid = Get-IpMachineSid
    $logged = Get-IpLoggedOnSids
    $assign = Read-IpLanguageAssignments -Settings $Settings
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { continue }
        $prop = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if (-not $prop -or -not $prop.PSObject.Properties['ProfileImagePath']) { continue }
        $path = [Environment]::ExpandEnvironmentVariables([string]$prop.ProfileImagePath)
        $folder = Split-Path -Leaf $path
        if ($folder -match '^(defaultuser\d+|TEMP)$') { continue }
        $name = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { '' }
        $so = New-Object Security.Principal.SecurityIdentifier $sid
        $kind = if ($sid -like 'S-1-12-1-*') { 'aad' }
        elseif ($machineSid -and $so.AccountDomainSid) { if ($so.AccountDomainSid.Value -eq $machineSid) { 'local' } else { 'domain' } }
        elseif ($name) { if (($name -split '\\')[0] -eq [Environment]::MachineName) { 'local' } else { 'domain' } }
        else { 'unknown' }
        $dat = Join-Path $path 'NTUSER.DAT'
        $last = try { (Get-Item -LiteralPath $dat -Force -ErrorAction Stop).LastWriteTime } catch { $null }
        $list.Add([pscustomobject]@{
                Sid = $sid; Name = $(if ($name) { $name } else { $folder }); Short = $(if ($name) { ($name -split '\\')[-1] } else { $folder }); Resolved = [bool]$name
                Kind = $kind; ProfilePath = $path; Loaded = (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid"); LoggedOn = $logged.ContainsKey($sid); LastUse = $last
                Current = (Get-IpHiveLanguage -Sid $sid); Assigned = $(if ($assign.ContainsKey($sid)) { $assign[$sid] } else { $null })
                Ad = $null; Suggested = $null; FromAd = $false
            })
    }
    # Přiřazení uživatelům, kteří tu ještě nemají profil (přidaní z AD) – aby šla zobrazit a zrušit.
    foreach ($sid in @($assign.Keys)) {
        if ($sid -eq 'default' -or @($list | Where-Object Sid -eq $sid).Count) { continue }
        $a = $assign[$sid]
        $list.Add([pscustomobject]@{ Sid = $sid; Name = [string]$a.Account; Short = ([string]$a.Account -split '\\')[-1]; Resolved = $true; Kind = 'domain'; ProfilePath = ''
                Loaded = $false; LoggedOn = $false; LastUse = $null; Current = $null; Assigned = $a; Ad = $null; Suggested = $null; FromAd = $true })
    }
    $ad = Get-IpAdUserInfo -Sids @($list | Where-Object Kind -eq 'domain' | ForEach-Object Sid)
    foreach ($u in $list) {
        if ($ad.ContainsKey($u.Sid)) { $u.Ad = $ad[$u.Sid]; $u.Suggested = Get-IpSuggestedLanguage -Languages $Languages -Ad $u.Ad }
    }
    return @($list | Sort-Object @{ Expression = { -not $_.LoggedOn } }, @{ Expression = { $_.Kind -ne 'domain' } }, Name)
}

function Find-IpAdUsers {
    # Hledání v AD (jméno, příjmení, login, e-mail) – pro uživatele, kteří na PC ještě nebyli přihlášení.
    param([Parameter(Mandatory)] $Languages, [Parameter(Mandatory)] [string] $Query)
    $q = $Query.Trim()
    if ($q.Length -lt 2) { throw 'Zadejte aspoň 2 znaky.' }
    if ($q -match '\\') { $q = ($q -split '\\')[-1] }
    $v = ConvertTo-IpLdapValue $q
    $ds = New-IpAdSearcher -Filter "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(|(anr=$v)(sAMAccountName=$v*)(userPrincipalName=$v*)))" -Size 25
    $out = foreach ($r in $ds.FindAll()) {
        $x = ConvertFrom-IpAdResult $r
        if (-not $x.Sid) { continue }
        $name = try { (New-Object Security.Principal.SecurityIdentifier $x.Sid).Translate([Security.Principal.NTAccount]).Value } catch { $x.Sam }
        [pscustomobject]@{ Sid = $x.Sid; Name = $name; Short = $x.Sam; Resolved = $true; Kind = 'domain'; ProfilePath = ''; Loaded = $false; LoggedOn = $false; LastUse = $null
            Current = $null; Assigned = $null; Ad = $x; Suggested = (Get-IpSuggestedLanguage -Languages $Languages -Ad $x); FromAd = $true }
    }
    return @($out)
}

function Resolve-IpAccount {
    # DOMENA\login, login@domena nebo SID -> účet. Pro příkazovou řádku.
    param([Parameter(Mandatory)] [string] $Name)
    if ($Name -eq 'default') { return [pscustomobject]@{ Sid = 'default'; Name = 'default'; ProfilePath = '' } }
    $sid = if ($Name -match '^S-1-[\d-]+$') { $Name } else { (New-Object Security.Principal.NTAccount($Name)).Translate([Security.Principal.SecurityIdentifier]).Value }
    $nt = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $Name }
    $prof = (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
    return [pscustomobject]@{ Sid = $sid; Name = $nt; ProfilePath = $(if ($prof) { [Environment]::ExpandEnvironmentVariables([string]$prof) } else { '' }) }
}

#endregion

#region Provedení (správce / SYSTEM)

function Register-IpLanguageTask {
    # Úloha při přihlášení kteréhokoli uživatele, běží POD NÍM (skupina Uživatelé, bez práv správce).
    param([Parameter(Mandatory)] [string] $Script)
    $grp = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $def = $svc.NewTask(0)
    $def.RegistrationInfo.Description = 'Při přihlášení nastaví uživateli jazyk, klávesnici a formáty podle přiřazení z Instalace programů (okno Jazyk uživatelů).'
    $def.Principal.GroupId = $grp
    $def.Principal.RunLevel = 0           # bez práv správce
    $def.Settings.MultipleInstances = 0   # souběžně (více uživatelů)
    $def.Settings.DisallowStartIfOnBatteries = $false
    $def.Settings.StopIfGoingOnBatteries = $false
    $def.Settings.ExecutionTimeLimit = 'PT10M'
    $def.Settings.Hidden = $true
    $def.Settings.Enabled = $true
    $t = $def.Triggers.Create(9)          # při přihlášení
    $t.Delay = 'PT10S'
    $a = $def.Actions.Create(0)
    $a.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
    [void]$svc.GetFolder('\').RegisterTaskDefinition($script:LangTaskName, $def, 6, $grp, $null, 4, $null)
}

function Install-IpLanguageAgent {
    # Zkopíruje skript pro uživatele do chráněné složky (zápis jen správci) a zaregistruje úlohu.
    param([Parameter(Mandatory)] $Settings)
    if (-not (Test-IpAdmin)) { throw 'Vyžaduje správce nebo SYSTEM.' }
    $p = Get-IpLanguagePaths $Settings
    [void](Initialize-IpSecureDirectory -Path $p.Dir)
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Apply-UserLanguage.ps1'
    if (-not (Test-Path -LiteralPath $src)) { throw "Chybí $src." }
    Copy-Item -LiteralPath $src -Destination $p.Script -Force
    Register-IpLanguageTask -Script $p.Script
}

function Install-IpLanguagePack {
    <#
    .SYNOPSIS
        Doinstaluje jazyk Windows. Windows 11: Install-Language (Windows Update). Windows 10: balíček
        *Language-Pack*<jazyk>*.cab z NAS (languagePackRoot) přes DISM. Vrací $true = nutný restart.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Languages, [Parameter(Mandatory)] [string] $Ui, [scriptblock] $Log, [int] $TimeoutMinutes = 90)
    # Čekání s hlášením průběhu každých 30 s (jinak okno minuty jen ukazuje Nastavuji…).
    $wait = {
        param([scriptblock] $IsDone, [scriptblock] $Stop, [string] $What)
        $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 30
        while (-not (& $IsDone)) {
            Start-Sleep -Seconds 2
            if ($sw.Elapsed.TotalSeconds -ge $next) {
                $next += 30
                if ($Log) { & $Log 'Info' ("{0} – běží {1:0} min {2:00} s…" -f $What, [Math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds) }
            }
            if ($sw.Elapsed.TotalMinutes -gt $TimeoutMinutes) { & $Stop; throw "nedokončeno do $TimeoutMinutes minut (pomalý internet / Windows Update?)" }
        }
    }
    if (Get-Command Install-Language -ErrorAction SilentlyContinue) {
        if ($Log) { & $Log 'Info' "Stahuji jazyk Windows $Ui z Windows Update (Install-Language)…" }
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddCommand('Install-Language').AddParameter('Language', $Ui).AddParameter('ErrorAction', 'Stop')
            $h = $ps.BeginInvoke()
            & $wait { $h.IsCompleted } { $ps.Stop() } "Stahování jazyka Windows $Ui"
            [void]$ps.EndInvoke($h)
            if ($ps.Streams.Error.Count) { throw $ps.Streams.Error[0].Exception }
        }
        finally { $ps.Dispose() }
        return $true
    }
    $root = $Languages.LanguagePackRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw "jazykový balíček $Ui není k dispozici – složka s balíčky ($root) neexistuje nebo NAS není dostupný" }
    $build = [Environment]::OSVersion.Version.Build
    $tags = @("$build"); if ($build -ge 19041 -and $build -le 19045) { $tags += '19041' }
    $cabs = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.cab' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Language-Pack' -and $_.Name -match ('[_-]' + [regex]::Escape($Ui) + '([_.-]|$)') })
    $pick = @(@($cabs | Where-Object { $p = $_.FullName; @($tags | Where-Object { $p -match "\b$_\b" }).Count }) + $cabs) | Select-Object -First 1
    if (-not $pick) { throw "na NAS ($root) není jazykový balíček pro $Ui (soubor *Language-Pack*$Ui*.cab pro Windows build $build)" }
    if ($Log) { & $Log 'Info' "Instaluji jazyk Windows $Ui z NAS: $($pick.FullName)" }
    $work = New-IpWorkFolder -Settings $Settings -Prefix 'lp'
    try {
        $local = Join-Path $work $pick.Name
        Copy-Item -LiteralPath $pick.FullName -Destination $local -Force
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') -ArgumentList "/Online /Add-Package /PackagePath:`"$local`" /NoRestart /Quiet" -PassThru -WindowStyle Hidden
        & $wait { $p.HasExited } { try { $p.Kill() } catch { } } "Instalace jazyka Windows $Ui (DISM)"
        $p.WaitForExit()
        if ($p.ExitCode -notin @(0, 3010)) { throw "DISM skončil s kódem $($p.ExitCode) (balíček nejspíš neodpovídá verzi Windows $build)" }
        return $true
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

function Set-IpOfflineUiLanguage {
    # Uživatel není přihlášený: jazyk Windows rovnou do jeho registru (NTUSER.DAT), aby se projevil
    # už při příštím přihlášení (jinak až po dalším odhlášení). Ostatní nastaví úloha při přihlášení.
    param([Parameter(Mandatory)] [string] $ProfilePath, [Parameter(Mandatory)] [string] $Ui)
    $dat = Join-Path $ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat)) { return $false }
    $mount = 'IP_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    & reg.exe load "HKU\$mount" "$dat" | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    try {
        $k = [Microsoft.Win32.Registry]::Users.CreateSubKey("$mount\Control Panel\Desktop")
        try { $k.SetValue('PreferredUILanguages', [string[]]@($Ui), [Microsoft.Win32.RegistryValueKind]::MultiString) } finally { $k.Dispose() }
        return $true
    }
    finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        for ($i = 0; $i -lt 5; $i++) { & reg.exe unload "HKU\$mount" | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 500 }
    }
}

function Invoke-IpLanguageChanges {
    <#
    .SYNOPSIS
        Uloží přiřazení jazyka a provede je. Spouští okno (jako správce), systémová úloha i příkazová řádka.
    .PARAMETER Changes
        @{ Sid; Account; ProfilePath; Language }  Language '' = zrušit přiřazení. Sid 'default' = noví uživatelé.
    .PARAMETER Parts
        keyboard, ui, region – co se má podle jazyka nastavit.
    .PARAMETER Machine
        @{ SystemLocale = 'de-DE'; TimeZone = 'W. Europe Standard Time' }  (prázdné = beze změny)
    #>
    param([Parameter(Mandatory)] $Settings, [object[]] $Changes = @(), [string[]] $Parts = $script:AllParts, $Machine, $Queue)
    $log = {
        param([string] $Level, [string] $Message)
        Write-IpLog -Settings $Settings -Level $Level -Message "Jazyk: $Message"
        if ($null -ne $Queue) { $Queue.Enqueue([pscustomobject]@{ Kind = 'langlog'; Level = $Level; Message = $Message }) }
    }
    $results = New-Object System.Collections.Generic.List[object]
    $res = { param($c, [string] $State, [string] $Msg) $results.Add([pscustomobject]@{ Sid = [string]$c.Sid; Account = [string]$c.Account; Language = [string]$c.Language; State = $State; Message = $Msg }) }
    $reboot = $false; $relogon = $false
    $Parts = @($Parts | Where-Object { $script:AllParts -contains $_ }); if (-not $Parts.Count) { $Parts = $script:AllParts }
    try {
        $langs = Read-IpLanguages -Settings $Settings
        $paths = Get-IpLanguagePaths $Settings
        try { Install-IpLanguageAgent -Settings $Settings }
        catch { & $log 'Warning' "Úlohu pro nastavení při přihlášení nejde připravit: $($_.Exception.Message). Nastaví se jen přihlášeným uživatelům." }

        # 1. jazyky Windows, které na PC chybí – jen zjistit. Stahují se až na konci (bod 5), protože
        #    to trvá i desítky minut a klávesnice a formáty se mají nastavit hned.
        $installed = @(Get-IpUiLanguages)
        $missingUi = @{}
        if ($Parts -contains 'ui') {
            foreach ($c in $Changes) {
                if (-not $c.Language) { continue }
                $l = $langs.ById[[string]$c.Language]
                if ($l -and $installed -notcontains $l.Ui) { $missingUi[$l.Ui] = 'missing' }
            }
        }

        # 2. přiřazení (musí být uložená dřív, než je skript pod uživatelem přečte)
        $map = Read-IpLanguageAssignments -Settings $Settings
        foreach ($c in $Changes) {
            $sid = [string]$c.Sid
            if ($sid -ne 'default' -and $sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { & $res $c 'err' 'neplatný účet'; continue }
            if (-not $c.Language) { [void]$map.Remove($sid); continue }
            if (-not $langs.ById.ContainsKey([string]$c.Language)) { & $res $c 'err' "jazyk $($c.Language) není v languages.json"; continue }
            $map[$sid] = New-IpLanguageAssignment -Languages $langs -Id ([string]$c.Language) -Parts $Parts -Account ([string]$c.Account)
        }
        Save-IpLanguageAssignments -Settings $Settings -Map $map

        # 3. provedení
        $logged = Get-IpLoggedOnSids
        foreach ($c in $Changes) {
            $sid = [string]$c.Sid
            if (@($results | Where-Object Sid -eq $sid).Count) { continue }
            $who = if ($sid -eq 'default') { 'noví uživatelé' } else { [string]$c.Account }
            if (-not $c.Language) { & $res $c 'removed' 'přiřazení zrušeno (nastavení uživatele se nemění)'; & $log 'Info' "$who – přiřazení zrušeno."; continue }
            $a = $map[$sid]
            $uiNote = if ($Parts -contains 'ui' -and $missingUi[$a.Ui]) { ' · jazyk Windows: balíček se stahuje, nastaví se po restartu a přihlášení' } else { '' }
            if ($sid -eq 'default') { & $res $c 'later' "nastaví se novým uživatelům při prvním přihlášení$uiNote"; & $log 'Info' "Výchozí jazyk pro nové uživatele: $($a.Name)."; continue }
            if ($logged.ContainsKey($sid) -and $c.Account -and $c.Account -match '\\') {
                try {
                    $code = Invoke-IpAsUser -User ([pscustomobject]@{ Name = [string]$c.Account }) -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($paths.Script)`"" -TimeoutMinutes 5
                    if ($code -eq 0 -or $code -eq 10) {
                        $m = 'nastaveno hned' + $(if ($Parts -contains 'ui' -and $code -eq 0) { ' · jazyk Windows po odhlášení' } else { '' }) + $(if ($code -eq 10) { ' · jazyk Windows: balíček se stahuje, nastaví se po restartu a přihlášení' } else { '' })
                        if ($Parts -contains 'ui' -and $code -eq 0) { $relogon = $true }
                        & $res $c $(if ($code -eq 10) { 'warn' } else { 'ok' }) $m; & $log 'Success' "$who – $($a.Name): $m."
                        continue
                    }
                    & $log 'Warning' "$who – nastavení pod uživatelem skončilo kódem $code, provede se při příštím přihlášení."
                } catch { & $log 'Warning' "$who – nejde spustit pod uživatelem ($($_.Exception.Message)), provede se při příštím přihlášení." }
                & $res $c 'later' "nastaví se při příštím přihlášení$uiNote"
                continue
            }
            $pre = $false
            if ($Parts -contains 'ui' -and $c.ProfilePath -and -not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") -and (Get-IpUiLanguages) -contains $a.Ui) {
                try { $pre = Set-IpOfflineUiLanguage -ProfilePath ([string]$c.ProfilePath) -Ui $a.Ui } catch { $pre = $false }
            }
            $m = "nastaví se při příštím přihlášení$uiNote"
            & $res $c 'later' $m; & $log 'Info' "$who – $($a.Name): $m$(if ($pre) { ' (jazyk Windows předem zapsán do profilu)' })."
        }

        # 4. celý počítač
        if ($Machine) {
            $sl = [string](Get-IpValue $Machine 'SystemLocale' '')
            if ($sl) {
                try { Set-WinSystemLocale -SystemLocale $sl; $reboot = $true; & $log 'Success' "Jazyk systému pro programy bez Unicode: $sl (projeví se po restartu)." }
                catch { & $log 'Error' "Jazyk systému $sl nejde nastavit: $($_.Exception.Message)" }
            }
            $tz = [string](Get-IpValue $Machine 'TimeZone' '')
            if ($tz) {
                try { Set-TimeZone -Id $tz -ErrorAction Stop; & $log 'Success' "Časové pásmo: $tz." }
                catch { & $log 'Error' "Časové pásmo $tz nejde nastavit: $($_.Exception.Message)" }
            }
        }

        # 5. chybějící jazyky Windows (dlouhé – stahování); přiřazení už jsou uložená a nastavená
        foreach ($ui in @($missingUi.Keys)) {
            & $log 'Info' "Jazyk Windows $ui na PC chybí – stahuji jazykový balíček. Obvykle to trvá 5–30 minut, okno můžete nechat otevřené."
            try { if (Install-IpLanguagePack -Settings $Settings -Languages $langs -Ui $ui -Log $log) { $reboot = $true }; & $log 'Success' "Jazyk Windows $ui nainstalován. Uživatelům se nastaví po restartu a přihlášení." }
            catch { & $log 'Warning' "Jazyk Windows $ui nejde doinstalovat: $($_.Exception.Message). Klávesnice a formáty jsou nastavené, jazyk Windows zůstane původní." }
        }
    }
    catch {
        $err = $_.Exception.Message
        & $log 'Error' $err
        foreach ($c in $Changes) { if (-not @($results | Where-Object Sid -eq ([string]$c.Sid)).Count) { & $res $c 'err' $err } }
    }
    if ($reboot) { & $log 'Warning' 'Některé změny se projeví až po restartu počítače.' }
    $done = [pscustomobject]@{ Kind = 'langdone'; Results = $results.ToArray(); Reboot = $reboot; Relogon = $relogon }
    if ($null -ne $Queue) { $Queue.Enqueue($done) }
    return $done
}

function Remove-IpUserProfiles {
    <#
    .SYNOPSIS
        Smaže profily uživatelů na tomto PC (složka C:\Users\... i záznam v registru, přes Win32_UserProfile).
        U místních účtů volitelně i účet. Doménové účty v AD se nikdy nemažou – jen jejich profil na PC.
    .PARAMETER Protect
        SID, které se smazat nesmí (ten, kdo maže). Vždy chránění jsou i přihlášení uživatelé,
        účet, pod kterým skript běží, a načtené / systémové profily.
    #>
    param([Parameter(Mandatory)] $Settings, [object[]] $Targets = @(), [string[]] $Protect = @(), $Queue)
    $log = {
        param([string] $Level, [string] $Message)
        Write-IpLog -Settings $Settings -Level $Level -Message "Profily: $Message"
        if ($null -ne $Queue) { $Queue.Enqueue([pscustomobject]@{ Kind = 'langlog'; Level = $Level; Message = $Message }) }
    }
    $results = New-Object System.Collections.Generic.List[object]
    try {
        if (-not (Test-IpAdmin)) { throw 'Mazání profilů vyžaduje správce nebo systémovou úlohu.' }
        $logged = Get-IpLoggedOnSids
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $machineSid = Get-IpMachineSid
        $assign = Read-IpLanguageAssignments -Settings $Settings; $assignChanged = $false
        foreach ($t in @($Targets | Select-Object -First 100)) {
            $sid = [string](Get-IpValue $t 'Sid' ''); $delAcc = [bool](Get-IpValue $t 'DeleteAccount' $false)
            $name = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
            try {
                if ($sid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { throw 'neplatný účet' }
                if ($Protect -contains $sid -or $sid -eq $me) { throw 'účet, pod kterým jste přihlášený, smazat nejde' }
                if ($logged.ContainsKey($sid) -or (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { throw 'uživatel je přihlášený nebo jeho profil používá jiný proces – odhlaste ho (případně restartujte PC) a zkuste znovu' }
                $msg = @()
                $up = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
                if ($up) {
                    if ($up.Special) { throw 'systémový profil se nemaže' }
                    if ($up.Loaded) { throw 'profil je načtený (uživatel je přihlášený)' }
                    & $log 'Info' "Mažu profil $name ($($up.LocalPath))…"
                    Remove-CimInstance -InputObject $up -ErrorAction Stop
                    $msg += "profil smazán ($($up.LocalPath))"
                }
                $so = New-Object Security.Principal.SecurityIdentifier $sid
                $local = $machineSid -and $so.AccountDomainSid -and $so.AccountDomainSid.Value -eq $machineSid
                if ($delAcc -and $local) {
                    if ($sid -match '-500$') { $msg += 'vestavěný účet Administrator se nemaže' }
                    else { Remove-LocalUser -SID $so -ErrorAction Stop; $msg += 'místní účet smazán' }
                }
                elseif ($delAcc) { $msg += 'doménový účet v AD zůstává' }
                if (-not $msg.Count) { throw 'na tomto PC nemá profil' }
                if ($assign.ContainsKey($sid)) { [void]$assign.Remove($sid); $assignChanged = $true }
                $results.Add([pscustomobject]@{ Sid = $sid; Account = $name; Language = ''; State = 'ok'; Message = ($msg -join ' · ') })
                & $log 'Success' "$name – $($msg -join ' · ')."
            }
            catch {
                $e = $_.Exception.Message
                $results.Add([pscustomobject]@{ Sid = $sid; Account = $name; Language = ''; State = 'err'; Message = "nesmazáno: $e" })
                & $log 'Error' "$name – nesmazáno: $e"
            }
        }
        if ($assignChanged) { try { Save-IpLanguageAssignments -Settings $Settings -Map $assign } catch { } }
    }
    catch { $e = $_.Exception.Message; & $log 'Error' $e; $results.Add([pscustomobject]@{ Sid = ''; Account = ''; Language = ''; State = 'err'; Message = $e }) }
    $done = [pscustomobject]@{ Kind = 'langdone'; Results = $results.ToArray(); Reboot = $false; Relogon = $false }
    if ($null -ne $Queue) { $Queue.Enqueue($done) }
    return $done
}

#endregion

Export-ModuleMember -Function @(
    'Remove-IpUserProfiles',
    'Read-IpLanguages', 'Get-IpLanguagePaths', 'Read-IpLanguageAssignments', 'Get-IpInstallLanguage', 'Get-IpUiLanguages', 'Get-IpMachineLanguageInfo',
    'Get-IpUserProfiles', 'Find-IpAdUsers', 'Resolve-IpAccount', 'Install-IpLanguageAgent', 'Install-IpLanguagePack', 'Invoke-IpLanguageChanges'
)
