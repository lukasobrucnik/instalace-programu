#Requires -Version 5.1
<#
.SYNOPSIS
    Společné funkce: nastavení, logování, chráněné složky, verze, přihlášený uživatel.
.NOTES
    Modul nezná GUI. Události posílá do fronty (ConcurrentQueue), kterou čte okno;
    bez fronty vypisuje do konzole (příkazová řádka).
#>

$script:UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
# SID, kterým věříme jako vlastníkům složek: SYSTEM, Administrators, TrustedInstaller.
$script:TrustedOwnerSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$script:SecuredDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:LogFile = $null

#region Nastavení

function Get-IpValue {
    # Bezpečně přečte volitelnou vlastnost objektu z JSON (chybějící = výchozí hodnota).
    param([AllowNull()] $Object, [Parameter(Mandatory)] [string] $Name, [AllowNull()] $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Read-IpJson {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Soubor nebyl nalezen: $Path" }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    try { return ($raw | ConvertFrom-Json) }
    catch { throw "Soubor '$Path' neobsahuje platný JSON: $($_.Exception.Message)" }
}

function Get-IpSettings {
    param([Parameter(Mandatory)] [string] $Path)
    $j = Read-IpJson -Path $Path
    $exp = { param($v) [Environment]::ExpandEnvironmentVariables([string]$v) }
    $system = & $exp (Get-IpValue $j 'dataDirectory' '%ProgramData%\InstalaceProgramu')
    # Bez práv správce (okno v režimu systémové úlohy) do ProgramData zapisovat nejde –
    # log a mezipaměť indexu jsou pak v profilu uživatele.
    $data = if (Test-IpAdmin) { $system } else { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'InstalaceProgramu' }
    return [pscustomobject]@{
        SystemDataDirectory       = $system
        AppDirectory              = & $exp (Get-IpValue $j 'appDirectory' '%ProgramFiles%\InstalaceProgramu')
        BrokerTaskName            = [string](Get-IpValue $j 'brokerTaskName' 'InstalaceProgramu-Broker')
        NoInteractive             = $false
        SourceRoots               = @(Get-IpValue $j 'sourceRoots' @() | ForEach-Object { (& $exp $_).TrimEnd('\') } | Where-Object { $_ })
        DeployPath                = & $exp (Get-IpValue $j 'deployPath' '')
        DataDirectory             = $data
        LogDirectory              = Join-Path $data 'Logs'
        TempDirectory             = Join-Path $data 'Temp'
        IndexPath                 = Join-Path $data 'nas-index.json'
        LanguagesPath             = Join-Path (Split-Path -Parent $Path) 'languages.json'
        # true = i uživatel bez práv správce (přes systémovou úlohu) smí nastavit jazyk komukoli a celému PC
        LanguageForAll            = [bool](Get-IpValue $j 'languageForAll' $true)
        # true = i uživatel bez práv správce smí mazat profily/účty ostatních (výchozí jen správce)
        ProfileDeleteForAll       = [bool](Get-IpValue $j 'profileDeleteForAll' $false)
        CentralLogDirectory       = & $exp (Get-IpValue $j 'centralLogDirectory' '')
        ScanDepth                 = [int](Get-IpValue $j 'scanDepth' 4)
        NasProbeSeconds           = [int](Get-IpValue $j 'nasProbeSeconds' 4)
        NasSlowMs                 = [int](Get-IpValue $j 'nasSlowMs' 500)
        InternetProbeUrl          = [string](Get-IpValue $j 'internetProbeUrl' 'https://cdn.winget.microsoft.com/cache/source.msix')
        InternetProbeSeconds      = [int](Get-IpValue $j 'internetProbeSeconds' 6)
        InternetSlowMs            = [int](Get-IpValue $j 'internetSlowMs' 2500)
        SilentTimeoutMinutes      = [int](Get-IpValue $j 'silentTimeoutMinutes' 40)
        InteractiveTimeoutMinutes = [int](Get-IpValue $j 'interactiveTimeoutMinutes' 120)
        DialogWatchSeconds        = [int](Get-IpValue $j 'dialogWatchSeconds' 25)
        MinFreeGb                 = [double](Get-IpValue $j 'minFreeGb' 5)
        BlockFreeGb               = [double](Get-IpValue $j 'blockFreeGb' 1)
        SophosMaxAgeDays          = [int](Get-IpValue $j 'sophosMaxAgeDays' 90)
        OfficeProductId           = [string](Get-IpValue $j 'officeProductId' 'O365BusinessRetail')
    }
}

#endregion

#region Chráněné složky (převzato ze vzoru sw-install)

function Test-IpAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-IpTrustedDirectory {
    # Odmítne odkaz (junction/symlink) a složku cizího vlastníka – běžný uživatel by jinak
    # mohl podstrčit instalátor, který se pak spustí s právy správce.
    param([Parameter(Mandatory)] [string] $Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Složka '$Path' je odkaz (junction/symlink) – z bezpečnostních důvodů ji nepoužiji."
    }
    if (-not (Test-IpAdmin)) { return }
    $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($script:TrustedOwnerSids -notcontains $owner -and $owner -ne $me) {
        throw "Složku '$Path' vlastní nedůvěryhodný účet ($owner). Smažte ji a spusťte instalátor znovu."
    }
}

function Set-IpProtectedAcl {
    # Zápis jen SYSTEM a Administrators, ostatní uživatelé smí číst a spouštět
    # (kvůli instalacím »jen pro uživatele«, které běží pod přihlášeným uživatelem).
    param([Parameter(Mandatory)] [string] $Path)
    $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'), @('S-1-5-32-545', 'ReadAndExecute'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier $r[0]
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, $r[1], $inh, 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Initialize-IpSecureDirectory {
    param([Parameter(Mandatory)] [string] $Path)
    if ($script:SecuredDirectories.Contains($Path)) { return $Path }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { [void](Initialize-IpSecureDirectory -Path $parent) }
    elseif ($parent) {
        $a = $parent
        while ($a -and -not $script:SecuredDirectories.Contains($a)) { Assert-IpTrustedDirectory -Path $a; $a = Split-Path -Parent $a }
    }
    if (Test-Path -LiteralPath $Path) { Assert-IpTrustedDirectory -Path $Path }
    else { New-Item -ItemType Directory -Path $Path | Out-Null }
    if ((Test-IpAdmin) -and -not $Path.StartsWith('\\')) { Set-IpProtectedAcl -Path $Path }
    [void]$script:SecuredDirectories.Add($Path)
    return $Path
}

function New-IpWorkFolder {
    # Pro každou instalaci nová složka s náhodným názvem v chráněném adresáři.
    param([Parameter(Mandatory)] $Settings, [string] $Prefix = 'job')
    $base = Initialize-IpSecureDirectory -Path $Settings.TempDirectory
    $dir = Join-Path $base ('{0}_{1}' -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

#endregion

#region Události a log

function Send-IpEvent {
    param([AllowNull()] $Queue, [Parameter(Mandatory)] [hashtable] $Data)
    if ($null -ne $Queue) { $Queue.Enqueue([pscustomobject]$Data); return }
    if ($Data['Kind'] -eq 'log') {
        $c = switch ($Data['Level']) { 'Error' { 'Red' } 'Warning' { 'Yellow' } 'Success' { 'Green' } default { 'Gray' } }
        Write-Host $Data['Message'] -ForegroundColor $c
    }
}

function Write-IpLog {
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')] [string] $Level = 'Info',
        [AllowNull()] $Queue
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level.ToUpperInvariant(), $Message
    try {
        if (-not $script:LogFile) {
            $dir = Initialize-IpSecureDirectory -Path $Settings.LogDirectory
            $script:LogFile = Join-Path $dir ('{0}_{1:yyyyMMdd}.log' -f [Environment]::MachineName, (Get-Date))
        }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    catch {
        # Log do záložní složky; když nejde ani ta, aspoň do okna.
        try {
            $alt = Join-Path $env:SystemRoot ('Temp\InstalaceProgramu_{0:yyyyMMdd}.log' -f (Get-Date))
            Add-Content -LiteralPath $alt -Value $line -Encoding UTF8
            $script:LogFile = $alt
        } catch { }
    }
    Send-IpEvent -Queue $Queue -Data @{ Kind = 'log'; Level = $Level; Message = $line }
}

function Get-IpLogFile { return $script:LogFile }

function Write-IpAudit {
    # Volitelný centrální CSV log (settings.centralLogDirectory). Chyba zápisu nic nezastaví.
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Result, [AllowNull()] $Queue)
    if ([string]::IsNullOrWhiteSpace($Settings.CentralLogDirectory)) { return }
    try {
        $file = Join-Path $Settings.CentralLogDirectory ('{0}.csv' -f [Environment]::MachineName)
        [pscustomobject]@{
            Cas = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Pocitac = [Environment]::MachineName
            Uzivatel = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
            Polozka = $Result.Id; Vysledek = $Result.Result; Zdroj = $Result.Source; Verze = $Result.Version
            Kod = $Result.ExitCode; Zprava = $Result.Message
        } | Export-Csv -LiteralPath $file -Append -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
    catch { Write-IpLog -Settings $Settings -Level Warning -Queue $Queue -Message "Centrální log nelze zapsat: $($_.Exception.Message)" }
}

#endregion

#region Verze a cesty

function ConvertTo-IpVersion {
    # Z textu vytáhne verzi (čísla oddělená tečkou); '' když tam žádná není.
    param([AllowNull()] [AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $m = [regex]::Match($Text, '\d+(?:[.,]\d+)*')
    if (-not $m.Success) { return '' }
    return ($m.Value -replace ',', '.')
}

function Compare-IpVersion {
    # -1 / 0 / 1; porovnává číselně po částech, ostatní znaky ignoruje.
    param([AllowNull()] [string] $A, [AllowNull()] [string] $B)
    $x = @([regex]::Matches([string]$A, '\d+') | ForEach-Object { [long]$_.Value })
    $y = @([regex]::Matches([string]$B, '\d+') | ForEach-Object { [long]$_.Value })
    $n = [Math]::Max($x.Count, $y.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = if ($i -lt $x.Count) { $x[$i] } else { 0 }
        $b = if ($i -lt $y.Count) { $y[$i] } else { 0 }
        if ($a -ne $b) { if ($a -gt $b) { return 1 } else { return -1 } }
    }
    return 0
}

function ConvertTo-IpUncPath {
    # Namapovaný disk (např. P:) proces s právy správce nevidí – převede se na \\server\share.
    param([string] $Path)
    if ($Path -notmatch '^([A-Za-z]):\\') { return $Path }
    $d = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($d -and $d.PSObject.Properties['DisplayRoot'] -and ([string]$d.DisplayRoot).StartsWith('\\')) {
        return ([string]$d.DisplayRoot).TrimEnd('\') + $Path.Substring(2)
    }
    try {
        $net = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Matches[1]):'" -ErrorAction Stop
        if ($net.ProviderName) { return $net.ProviderName.TrimEnd('\') + $Path.Substring(2) }
    } catch { }
    return $Path
}

#endregion

#region Přihlášený uživatel

function Get-IpLoggedOnUser {
    <#
    .SYNOPSIS
        Zjistí uživatele přihlášeného u konzole (vlastník explorer.exe).
    .NOTES
        Aplikace často běží pod jiným správcovským účtem. Instalace »jen pro uživatele«
        proto musí běžet v relaci tohoto uživatele, ne v procesu aplikace.
    #>
    try {
        $sessionId = (Get-Process -Id $PID).SessionId
        $explorers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
        $pick = @($explorers | Where-Object { $_.SessionId -eq $sessionId }) + @($explorers) | Select-Object -First 1
        if (-not $pick) { return $null }
        $o = Invoke-CimMethod -InputObject $pick -MethodName GetOwner -ErrorAction Stop
        if (-not $o.User) { return $null }
        $name = if ($o.Domain) { "$($o.Domain)\$($o.User)" } else { $o.User }
        $sid = (New-Object Security.Principal.NTAccount($name)).Translate([Security.Principal.SecurityIdentifier]).Value
        $profile = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
        return [pscustomobject]@{ Name = $name; Short = $o.User; Sid = $sid; ProfilePath = $profile }
    }
    catch { return $null }
}

function Invoke-IpAsUser {
    <#
    .SYNOPSIS
        Spustí program v relaci přihlášeného uživatele (bez práv správce) přes jednorázovou
        naplánovanou úlohu a počká na konec. Vrací návratový kód.
    #>
    param(
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] [string] $FilePath,
        [AllowEmptyString()] [string] $Arguments = '',
        [int] $TimeoutMinutes = 40
    )
    $name = 'InstalaceProgramu_' + [guid]::NewGuid().ToString('N').Substring(0, 10)
    $actionArgs = @{ Execute = $FilePath }
    if ($Arguments) { $actionArgs.Argument = $Arguments }
    $action = New-ScheduledTaskAction @actionArgs
    $principal = New-ScheduledTaskPrincipal -UserId $User.Name -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes)
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $name
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds 800
        while ($true) {
            $info = Get-ScheduledTaskInfo -TaskName $name
            $state = (Get-ScheduledTask -TaskName $name).State
            # 267009 = úloha běží, 267011 = ještě nespuštěna
            if ($state -ne 'Running' -and $info.LastTaskResult -notin @(267009, 267011)) { return [int]$info.LastTaskResult }
            if ($sw.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
                Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
                throw "Instalace pod uživatelem $($User.Name) nedoběhla do $TimeoutMinutes minut."
            }
            Start-Sleep -Seconds 2
        }
    }
    finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
}

function Get-IpUninstallEntries {
    # Nainstalované programy z registru: pro všechny (HKLM) i pro přihlášeného uživatele (HKU\SID).
    param([string] $UserSid)
    $keys = @($script:UninstallKeys)
    if ($UserSid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$UserSid")) {
        $keys += "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    }
    $out = foreach ($k in $keys) {
        $scope = if ($k -like 'Registry::HKEY_USERS*') { 'user' } else { 'all' }
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -and -not ($_.PSObject.Properties['SystemComponent'] -and $_.SystemComponent -eq 1) } |
            ForEach-Object {
                $v = if ($_.PSObject.Properties['DisplayVersion']) { [string]$_.DisplayVersion } else { '' }
                [pscustomobject]@{ DisplayName = [string]$_.DisplayName; DisplayVersion = $v; Scope = $scope }
            }
    }
    return @($out)
}

#endregion

Export-ModuleMember -Function @(
    'Get-IpValue', 'Read-IpJson', 'Get-IpSettings', 'Test-IpAdmin', 'Assert-IpTrustedDirectory', 'Initialize-IpSecureDirectory', 'New-IpWorkFolder',
    'Send-IpEvent', 'Write-IpLog', 'Get-IpLogFile', 'Write-IpAudit', 'ConvertTo-IpVersion', 'Compare-IpVersion',
    'ConvertTo-IpUncPath', 'Get-IpLoggedOnUser', 'Invoke-IpAsUser', 'Get-IpUninstallEntries'
)
