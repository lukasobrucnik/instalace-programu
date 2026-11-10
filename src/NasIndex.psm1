#Requires -Version 5.1
<#
.SYNOPSIS
    Katalog a offline prohledání NAS: pozná programy podle pravidel, přečte verze z metadat,
    seřadí verze a označí doporučenou. Nic nespouští ani na NAS nemění.
.NOTES
    Výsledek se ukládá jako mezipaměť (nas-index.json). Nezměněné soubory (cesta + velikost
    + čas změny) se při dalším spuštění nečtou znovu. Když je NAS nedostupný, použije se uložený index.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

$script:InstallerExt = '^\.(msi|exe|msix|msixbundle|appx|ttf|otf|zip)$'
$script:UnstableRe = '(?i)(beta|alpha|preview|\brc\d*\b|-rc)'
$script:MetaSchema = 2
$script:DefaultSilent = @{
    inno          = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    nsis          = '/S'
    burn          = '/quiet /norestart'
    installshield = '/s /v"/qn REBOOT=ReallySuppress"'
}

#region Katalog

function Read-IpCatalog {
    <#
    .SYNOPSIS
        Načte catalog.json, doplní výchozí hodnoty a zkontroluje odkazy. Chyby vyhodí srozumitelně.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    $j = Read-IpJson -Path $Path
    $errors = New-Object System.Collections.Generic.List[string]
    $cats = @(Get-IpValue $j 'categories' @())
    $catIds = @($cats | ForEach-Object { $_.id })
    $items = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    foreach ($it in @(Get-IpValue $j 'items' @())) {
        $id = [string](Get-IpValue $it 'id' '')
        if (-not $id) { $errors.Add('Položka bez id.'); continue }
        if ($byId.ContainsKey($id)) { $errors.Add("Duplicitní id '$id'."); continue }
        $match = [string](Get-IpValue $it 'match' '')
        if ($match) { try { [void][regex]::new($match) } catch { $errors.Add("Položka '$id': neplatný regulární výraz 'match'.") } }
        $cat = [string](Get-IpValue $it 'category' '')
        if ($catIds -notcontains $cat) { $errors.Add("Položka '$id': neznámá kategorie '$cat'.") }
        $o = [pscustomobject]@{
            Id = $id; Name = [string](Get-IpValue $it 'name' $id); Category = $cat
            Required = [bool](Get-IpValue $it 'required' $false); Type = [string](Get-IpValue $it 'type' '')
            Match = $match; VersionRegex = [string](Get-IpValue $it 'versionRegex' ''); VersionFormat = [string](Get-IpValue $it 'versionFormat' '$1')
            Rank = @(Get-IpValue $it 'rank' @()); Prefer = @(Get-IpValue $it 'prefer' @('msi', 'exe'))
            Args = (Get-IpValue $it 'args' ([pscustomobject]@{})); Winget = [string](Get-IpValue $it 'winget' '')
            Sources = @(Get-IpValue $it 'sources' @('nas', 'winget')); Scope = [string](Get-IpValue $it 'scope' 'machine')
            Recommended = [string](Get-IpValue $it 'recommended' 'all'); Why = [string](Get-IpValue $it 'why' '')
            Detect = [string](Get-IpValue $it 'detect' ''); DetectAppx = [string](Get-IpValue $it 'detectAppx' '')
            Interactive = [bool](Get-IpValue $it 'interactive' $false); NasInteractive = [bool](Get-IpValue $it 'nasInteractive' $false)
            NasNeedsInternet = [bool](Get-IpValue $it 'nasNeedsInternet' $false); KeepFileName = [bool](Get-IpValue $it 'keepFileName' $false)
            CloseProcesses = @(Get-IpValue $it 'closeProcesses' @()); Dialogs = @(Get-IpValue $it 'dialogs' @())
            Shortcut = [string](Get-IpValue $it 'shortcut' ''); Pin = [bool](Get-IpValue $it 'pin' $false)
            TrustCertificates = [bool](Get-IpValue $it 'trustCertificates' $false); Notes = [string](Get-IpValue $it 'notes' '')
            Exception = $false
        }
        if ($o.Scope -notin @('machine', 'both')) { $errors.Add("Položka '$id': scope musí být 'machine' nebo 'both'.") }
        if (-not $o.Match -and -not $o.Winget) { $errors.Add("Položka '$id': chybí 'match' i 'winget' – nemá odkud se instalovat.") }
        $items.Add($o); $byId[$id] = $o
    }
    $bundles = foreach ($b in @(Get-IpValue $j 'bundles' @())) {
        $ids = @(Get-IpValue $b 'items' @())
        foreach ($x in $ids) { if (-not $byId.ContainsKey($x)) { $errors.Add("Balíček '$($b.id)': neznámá položka '$x'.") } }
        [pscustomobject]@{ Id = [string]$b.id; Name = [string]$b.name; Description = [string](Get-IpValue $b 'description' ''); Items = $ids }
    }
    if ($errors.Count -gt 0) { throw ("Chyba v katalogu ($Path):`n - " + ($errors -join "`n - ")) }
    return [pscustomobject]@{
        Categories = $cats; Bundles = @($bundles); Items = $items.ToArray(); ById = $byId
        ExcludeFolders = @(Get-IpValue $j 'excludeFolders' @()); ExcludeFiles = @(Get-IpValue $j 'excludeFiles' @())
    }
}

#endregion

#region Metadata souborů

function Get-IpMsiProperties {
    # Čte tabulku Property z MSI (databáze otevřená jen pro čtení).
    param([Parameter(Mandatory)] [string] $Path)
    $props = @{}
    $inst = $null; $db = $null; $view = $null
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        $db = $inst.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $inst, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT Property, Value FROM Property'))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        while ($true) {
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($null -eq $rec) { break }
            $k = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1)
            $v = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 2)
            $props[$k] = $v
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
        }
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
    }
    catch { }
    finally {
        foreach ($c in @($view, $db, $inst)) { if ($c) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($c) } }
    }
    return $props
}

function Get-IpInstallerKind {
    <#
    .SYNOPSIS
        Pozná typ instalátoru (msi, msix, font, zip, inno, nsis, burn, installshield, exe)
        podle přípony, informací o verzi a značek v prvních 768 kB souboru.
    #>
    param([Parameter(Mandatory)] [string] $Path)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.msi' { return 'msi' } '.msix' { return 'msix' } '.msixbundle' { return 'msix' } '.appx' { return 'msix' }
        '.ttf' { return 'font' } '.otf' { return 'font' } '.zip' { return 'zip' }
    }
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ("$($vi.Comments) $($vi.FileDescription)" -match 'Inno Setup') { return 'inno' }
        if ("$($vi.CompanyName) $($vi.Comments)" -match 'InstallShield') { return 'installshield' }
    } catch { }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $buf = New-Object byte[] ([Math]::Min(786432, $fs.Length))
            [void]$fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        $s = [Text.Encoding]::ASCII.GetString($buf)
        if ($s.Contains('.wixburn')) { return 'burn' }
        if ($s.Contains('Inno Setup')) { return 'inno' }
        if ($s.Contains('Nullsoft')) { return 'nsis' }
        if ($s.Contains('InstallShield')) { return 'installshield' }
    } catch { }
    return 'exe'
}

function Get-IpDefaultSilentArgs {
    param([string] $Kind)
    if ($script:DefaultSilent.ContainsKey($Kind)) { return $script:DefaultSilent[$Kind] }
    return $null
}

function Get-IpFileMeta {
    param([Parameter(Mandatory)] [IO.FileInfo] $File)
    $kind = Get-IpInstallerKind -Path $File.FullName
    $product = ''; $company = ''; $ver = ''; $perUser = $false
    if ($kind -eq 'msi') {
        $p = Get-IpMsiProperties -Path $File.FullName
        $product = [string]$p['ProductName']; $company = [string]$p['Manufacturer']; $ver = ConvertTo-IpVersion $p['ProductVersion']
        $perUser = ([string]$p['ALLUSERS'] -eq '2') -or $p.ContainsKey('MSIINSTALLPERUSER')
    }
    elseif ($kind -ne 'font' -and $kind -ne 'zip' -and $kind -ne 'msix') {
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($File.FullName)
            $product = [string]$vi.ProductName; $company = [string]$vi.CompanyName
            $ver = ConvertTo-IpVersion $vi.ProductVersion
            if (-not $ver -or $ver -match '^0(\.0)*$') { $ver = ConvertTo-IpVersion $vi.FileVersion }
            if ($ver -match '^0(\.0)*$') { $ver = '' }
        } catch { }
    }
    elseif ($kind -eq 'msix') {
        # Verze a název z manifestu balíčku (čte se jen adresář ZIP, ne celý soubor).
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($File.FullName)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -in @('AppxManifest.xml', 'AppxMetadata/AppxBundleManifest.xml') } | Select-Object -First 1
                if ($entry) {
                    $sr = New-Object IO.StreamReader($entry.Open())
                    try { [xml]$x = $sr.ReadToEnd() } finally { $sr.Dispose() }
                    $idNode = $x.SelectSingleNode("//*[local-name()='Identity']")
                    if ($idNode) { $ver = ConvertTo-IpVersion $idNode.Version; $product = [string]$idNode.Name }
                }
            } finally { $zip.Dispose() }
        } catch { }
    }
    elseif ($kind -eq 'font') {
        try {
            Add-Type -AssemblyName System.Drawing
            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            $pfc.AddFontFile($File.FullName); $product = $pfc.Families[0].Name; $pfc.Dispose()
        } catch { $product = $File.BaseName }
    }
    return [pscustomobject]@{ Kind = $kind; Product = $product; Company = $company; MetaVersion = $ver; PerUser = $perUser }
}

#endregion

#region Prohledání NAS

function Test-IpLike {
    # Wildcard porovnání relativní cesty (lomítka sjednocená na '/').
    param([string] $Rel, [string] $Pattern)
    return ($Rel -like $Pattern) -or ($Rel -like "$Pattern/*")
}

function Resolve-IpVersion {
    param($Item, [string] $Rel, $Meta, [datetime] $Modified)
    if ($Item.VersionRegex) {
        $m = [regex]::Match([IO.Path]::GetFileName($Rel), $Item.VersionRegex, 'IgnoreCase')
        if (-not $m.Success) { $m = [regex]::Match($Rel, $Item.VersionRegex, 'IgnoreCase') }
        if ($m.Success) { return $m.Result($Item.VersionFormat) }
    }
    if ($Meta.MetaVersion) { return $Meta.MetaVersion }
    $fromName = ConvertTo-IpVersion ([IO.Path]::GetFileNameWithoutExtension($Rel) -replace '(?i)x64|x86|win64|win32|64bit|32bit', '')
    if ($fromName -match '\.') { return $fromName }
    return $Modified.ToString('yyyy-MM-dd')
}

function Read-IpIndexCache {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Invoke-IpNasScan {
    <#
    .SYNOPSIS
        Prohledá zdrojové složky NAS a vrátí index: kandidáti pro každou položku katalogu,
        vyloučené a nerozpoznané soubory. Při nedostupném NAS vrátí uložený index.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Catalog, [AllowNull()] $Queue)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $old = Read-IpIndexCache -Path $Settings.IndexPath
    $metaCache = @{}
    # Mezipaměť metadat se použije jen ze stejné verze čtení metadat (po změně logiky se čte znovu).
    if ($old -and $old.PSObject.Properties['Meta'] -and (Get-IpValue $old 'MetaSchema' 0) -eq $script:MetaSchema) {
        foreach ($p in $old.Meta.PSObject.Properties) { $metaCache[$p.Name] = $p.Value }
    }

    $roots = foreach ($r in $Settings.SourceRoots) { [pscustomobject]@{ Path = $r; Reachable = [bool](Test-Path -LiteralPath $r -ErrorAction SilentlyContinue) } }
    $roots = @($roots)
    if (-not (@($roots | Where-Object Reachable).Count)) {
        if ($old) {
            $old | Add-Member -NotePropertyName FromCache -NotePropertyValue $true -Force
            Send-IpEvent -Queue $Queue -Data @{ Kind = 'scan'; Message = 'NAS je nedostupný – použit uložený index.' }
            return (ConvertFrom-IpIndexJson $old)
        }
        return [pscustomobject]@{ ScannedAt = $null; Roots = $roots; FromCache = $false; Items = @{}; Excluded = @(); ExcludedFolders = @(); Unrecognized = @(); Meta = @{}; Stats = @{ Files = 0 } }
    }

    $cands = @{}; $excluded = New-Object System.Collections.Generic.List[object]
    $exFolders = New-Object System.Collections.Generic.List[object]; $unrec = New-Object System.Collections.Generic.List[object]
    $newMeta = @{}; $files = 0; $readMeta = 0
    $matchers = @($Catalog.Items | Where-Object { $_.Match } | ForEach-Object { [pscustomobject]@{ Item = $_; Re = [regex]::new($_.Match, 'IgnoreCase') } })

    foreach ($root in @($roots | Where-Object Reachable)) {
        $stack = New-Object System.Collections.Stack
        $stack.Push(@($root.Path, '', 0))
        while ($stack.Count -gt 0) {
            $cur = $stack.Pop(); $dir = $cur[0]; $relDir = $cur[1]; $depth = $cur[2]
            $entries = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
            foreach ($d in @($entries | Where-Object PSIsContainer)) {
                $rel = if ($relDir) { "$relDir/$($d.Name)" } else { $d.Name }
                $rule = @($Catalog.ExcludeFolders | Where-Object { $rel -like $_.path }) | Select-Object -First 1
                if ($rule) { $exFolders.Add([pscustomobject]@{ Rel = $rel; Reason = [string]$rule.reason }); continue }
                if ($depth + 1 -lt $Settings.ScanDepth) { $stack.Push(@($d.FullName, $rel, ($depth + 1))) }
            }
            foreach ($f in @($entries | Where-Object { -not $_.PSIsContainer -and $_.Extension -match $script:InstallerExt })) {
                $files++
                $rel = if ($relDir) { "$relDir/$($f.Name)" } else { $f.Name }
                $base = [pscustomobject]@{ Rel = $rel; Path = $f.FullName; Root = $root.Path; Size = $f.Length; Modified = $f.LastWriteTime; Ext = $f.Extension.TrimStart('.').ToLowerInvariant() }
                $xr = @($Catalog.ExcludeFiles | Where-Object { Test-IpLike -Rel $rel -Pattern $_.path }) | Select-Object -First 1
                if ($xr) {
                    $base | Add-Member -NotePropertyMembers @{ Reason = [string]$xr.reason; Risk = [string](Get-IpValue $xr 'risk' 'warn'); Kind = 'excluded' }
                    $excluded.Add($base); continue
                }
                $hit = $null
                foreach ($m in $matchers) { if ($m.Re.IsMatch($rel)) { $hit = $m.Item; break } }
                if (-not $hit) {
                    $base | Add-Member -NotePropertyMembers @{ Reason = 'neodpovídá žádnému pravidlu v katalogu'; Risk = 'err'; Kind = 'unrecognized' }
                    $unrec.Add($base); continue
                }
                $key = '{0}|{1}|{2}' -f $rel, $f.Length, $f.LastWriteTimeUtc.Ticks
                $meta = $metaCache[$key]
                if (-not $meta) {
                    $meta = Get-IpFileMeta -File $f; $readMeta++
                    Send-IpEvent -Queue $Queue -Data @{ Kind = 'scan'; Message = "Čtu metadata: $rel" }
                }
                $newMeta[$key] = $meta
                $ver = Resolve-IpVersion -Item $hit -Rel $rel -Meta $meta -Modified $f.LastWriteTime
                $base | Add-Member -NotePropertyMembers @{
                    ItemId = $hit.Id; Kind = [string]$meta.Kind; Product = [string]$meta.Product; Company = [string]$meta.Company
                    PerUser = [bool]$meta.PerUser; Version = $ver; Recommended = $false
                }
                if (-not $cands.ContainsKey($hit.Id)) { $cands[$hit.Id] = New-Object System.Collections.Generic.List[object] }
                $cands[$hit.Id].Add($base)
            }
        }
    }

    # Seřazení: nejnovější verze první; u stejné verze vyhraje pořadí 'rank', pak preferovaná přípona, pak novější soubor.
    $items = @{}
    foreach ($id in $cands.Keys) {
        $it = $Catalog.ById[$id]
        $scored = foreach ($c in $cands[$id]) {
            $rk = 99; for ($i = 0; $i -lt $it.Rank.Count; $i++) { if ($c.Rel -like "*$($it.Rank[$i])*") { $rk = $i; break } }
            $pf = [array]::IndexOf([string[]]$it.Prefer, $c.Ext); if ($pf -lt 0) { $pf = 99 }
            [pscustomobject]@{ C = $c; Rank = $rk; Pref = $pf }
        }
        $byVer = @{}
        foreach ($s in @($scored)) {
            $k = $s.C.Version
            if (-not $byVer.ContainsKey($k)) { $byVer[$k] = $s; continue }
            $b = $byVer[$k]
            if ($s.Rank -lt $b.Rank -or ($s.Rank -eq $b.Rank -and ($s.Pref -lt $b.Pref -or ($s.Pref -eq $b.Pref -and $s.C.Modified -gt $b.C.Modified)))) { $byVer[$k] = $s }
        }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($s in $byVer.Values) { $list.Add($s.C) }
        $list.Sort([Comparison[object]] {
                param($a, $b)
                # Skutečná verze má přednost před datem souboru (náhradní »verze« bez metadat).
                $da = $a.Version -match '^\d{4}-\d{2}-\d{2}$'; $db = $b.Version -match '^\d{4}-\d{2}-\d{2}$'
                if ($da -ne $db) { if ($da) { return 1 } else { return -1 } }
                $c = Compare-IpVersion $b.Version $a.Version
                if ($c -ne 0) { return $c }
                return $b.Modified.CompareTo($a.Modified)
            })
        $rec = @($list | Where-Object { $_.Rel -notmatch $script:UnstableRe -and $_.Version -notmatch $script:UnstableRe }) | Select-Object -First 1
        if (-not $rec) { $rec = $list[0] }
        $rec.Recommended = $true
        $items[$id] = $list.ToArray()
    }

    $index = [pscustomobject]@{
        ScannedAt = Get-Date; Roots = $roots; FromCache = $false; Items = $items; MetaSchema = $script:MetaSchema
        Excluded = $excluded.ToArray(); ExcludedFolders = $exFolders.ToArray(); Unrecognized = $unrec.ToArray(); Meta = $newMeta
        Stats = @{ Files = $files; Recognized = $items.Count; Multi = @($items.Values | Where-Object { @($_).Count -gt 1 }).Count; ReadMeta = $readMeta; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    try {
        [void](Initialize-IpSecureDirectory -Path $Settings.DataDirectory)
        $index | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $Settings.IndexPath -Encoding UTF8 -ErrorAction Stop
    } catch { Send-IpEvent -Queue $Queue -Data @{ Kind = 'scan'; Message = "Index nelze uložit: $($_.Exception.Message)" } }
    return $index
}

function ConvertTo-IpDate {
    # ConvertTo-Json ve Windows PowerShell 5.1 ukládá datum jako "\/Date(ms)\/".
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    if ("$Value" -match 'Date\((-?\d+)') { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Matches[1]).LocalDateTime }
    try { return [datetime]$Value } catch { return [datetime]::MinValue }
}

function ConvertFrom-IpIndexJson {
    # Uložený index (PSCustomObject z JSON) převede zpět na tvar, jaký vrací Invoke-IpNasScan.
    param([Parameter(Mandatory)] $Json)
    $items = @{}
    if ($Json.Items) { foreach ($p in $Json.Items.PSObject.Properties) { $items[$p.Name] = @($p.Value | ForEach-Object { $_.Modified = ConvertTo-IpDate $_.Modified; $_ }) } }
    $fix = { param($arr) @($arr | Where-Object { $_ } | ForEach-Object { $_.Modified = ConvertTo-IpDate $_.Modified; $_ }) }
    return [pscustomobject]@{
        ScannedAt = if ($Json.ScannedAt) { ConvertTo-IpDate $Json.ScannedAt } else { $null }; Roots = @($Json.Roots)
        FromCache = [bool](Get-IpValue $Json 'FromCache' $true); Items = $items
        Excluded = & $fix $Json.Excluded; ExcludedFolders = @($Json.ExcludedFolders); Unrecognized = & $fix $Json.Unrecognized
        Meta = @{}; Stats = @{ Files = [int](Get-IpValue $Json.Stats 'Files' 0); Recognized = $items.Count; Multi = @($items.Values | Where-Object { @($_).Count -gt 1 }).Count }
    }
}

function Get-IpCandidates {
    # Bez indexu (kontrola ještě běží / NAS nikdy nebyl dostupný) = žádní kandidáti.
    param([AllowNull()] $Index, [Parameter(Mandatory)] [string] $ItemId)
    if ($Index -and $Index.Items -and $Index.Items.ContainsKey($ItemId)) { return @($Index.Items[$ItemId]) }
    return @()
}

#endregion

Export-ModuleMember -Function @(
    'Read-IpCatalog', 'Get-IpMsiProperties', 'Get-IpInstallerKind', 'Get-IpDefaultSilentArgs', 'Get-IpFileMeta',
    'Invoke-IpNasScan', 'ConvertFrom-IpIndexJson', 'Get-IpCandidates', 'Read-IpIndexCache'
)
