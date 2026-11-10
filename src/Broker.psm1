#Requires -Version 5.1
<#
.SYNOPSIS
    Instalace bez práv správce: okno běží pod uživatelem, instaluje systémová úloha (SYSTEM).
.DESCRIPTION
    Úlohu na PC jednou zaregistruje tools\Install-Broker.ps1 (GPO, spouštěcí skript počítače).
    Kdokoli přihlášený ji smí spustit, ale nic jiného s ní dělat nesmí.

    Okno -> úloha: Requests\<id>.json  (jen ID programů z katalogu, verze a rozsah – žádné cesty
                   ani příkazy; úloha si plán sestaví sama z vlastního katalogu a indexu NAS)
                   Requests\<id>.cancel  (zastavit po aktuální položce)
    Úloha -> okno: Status\<id>.jsonl    (stejné události jako fronta okna, jeden JSON na řádek)
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'NasIndex.psm1')
Import-Module (Join-Path $PSScriptRoot 'Health.psm1')
Import-Module (Join-Path $PSScriptRoot 'Install.psm1')
Import-Module (Join-Path $PSScriptRoot 'Language.psm1')

# Úlohu smí číst a spustit přihlášení uživatelé (AU), měnit jen SYSTEM a správci.
$script:TaskSddl = 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)'
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Get-IpBrokerPaths {
    param([Parameter(Mandatory)] $Settings)
    return @{
        Requests = Join-Path $Settings.SystemDataDirectory 'Requests'
        Status   = Join-Path $Settings.SystemDataDirectory 'Status'
    }
}

function Get-IpBrokerTask {
    param([Parameter(Mandatory)] $Settings)
    try {
        $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
        return $svc.GetFolder('\').GetTask($Settings.BrokerTaskName)
    } catch { return $null }
}

function Test-IpBroker {
    # Je na tomto PC systémová úloha a smí ji tento účet spustit?
    param([Parameter(Mandatory)] $Settings)
    $t = Get-IpBrokerTask -Settings $Settings
    return [bool]($t -and $t.Enabled -and (Test-Path -LiteralPath (Get-IpBrokerPaths $Settings).Requests))
}

#region Nasazení (spouští tools\Install-Broker.ps1 jako SYSTEM / správce)

function Set-IpRequestsAcl {
    # Uživatelé smí ve složce jen zakládat soubory (ne vypisovat, ne zakládat podsložky);
    # svůj soubor smí upravit. Ostatní požadavky nevidí ani nezmění.
    param([Parameter(Mandatory)] [string] $Path)
    $none = [Security.AccessControl.InheritanceFlags]::None
    $files = [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $all = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    $rule = { param($sid, $rights, $inh, $prop) $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), $rights, $inh, $prop, 'Allow'))) }
    & $rule 'S-1-5-18' 'FullControl' $all 'None'
    & $rule 'S-1-5-32-544' 'FullControl' $all 'None'
    & $rule 'S-1-5-11' ([Security.AccessControl.FileSystemRights]'CreateFiles, ReadAttributes, Synchronize') $none 'None'
    & $rule 'S-1-3-0' 'Modify' $files 'InheritOnly'
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Register-IpBroker {
    <#
    .SYNOPSIS
        Zaregistruje (nebo aktualizuje) systémovou úlohu a připraví složky. Spouští se jako SYSTEM/správce.
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $StartScript)
    if (-not (Test-IpAdmin)) { throw 'Registrace systémové úlohy vyžaduje SYSTEM nebo správce.' }
    $p = Get-IpBrokerPaths $Settings
    [void](Initialize-IpSecureDirectory -Path $Settings.SystemDataDirectory)
    [void](Initialize-IpSecureDirectory -Path $p.Status)
    if (-not (Test-Path -LiteralPath $p.Requests)) { New-Item -ItemType Directory -Path $p.Requests | Out-Null }
    Assert-IpTrustedDirectory -Path $p.Requests
    Set-IpRequestsAcl -Path $p.Requests

    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $def = $svc.NewTask(0)
    $def.RegistrationInfo.Description = 'Instalace programů z firemního NAS na žádost přihlášeného uživatele (bez práv správce).'
    $def.Principal.UserId = 'S-1-5-18'
    $def.Principal.LogonType = 5          # služba (SYSTEM)
    $def.Principal.RunLevel = 1           # nejvyšší oprávnění
    $def.Settings.MultipleInstances = 1   # další spuštění počká ve frontě
    $def.Settings.DisallowStartIfOnBatteries = $false
    $def.Settings.StopIfGoingOnBatteries = $false
    $def.Settings.AllowDemandStart = $true
    $def.Settings.ExecutionTimeLimit = 'PT12H'
    $def.Settings.Enabled = $true
    $a = $def.Actions.Create(0)
    $a.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartScript`""
    # 6 = vytvořit nebo aktualizovat; poslední parametr = oprávnění úlohy
    [void]$svc.GetFolder('\').RegisterTaskDefinition($Settings.BrokerTaskName, $def, 6, 'SYSTEM', $null, 5, $script:TaskSddl)
}

#endregion

#region Strana okna (běží pod uživatelem)

function Read-IpStatusLines {
    # Přečte nové celé řádky ze stavového souboru od pozice $Offset (soubor zapisuje úloha).
    param([string] $Path, [ref] $Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($fs.Length -le $Offset.Value) { return @() }
        [void]$fs.Seek($Offset.Value, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $Offset.Value)
        $n = $fs.Read($buf, 0, $buf.Length)
        $end = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
        if ($end -lt 0) { return @() }
        $Offset.Value += $end + 1
        return @($script:Utf8.GetString($buf, 0, $end + 1) -split "`n" | Where-Object { $_.Trim() })
    }
    finally { $fs.Dispose() }
}

function Send-IpBrokerFailure {
    # Úloha nereaguje: zbylé položky označí jako selhané se srozumitelným návodem.
    param($Plan, $Queue, [string[]] $DoneIds, [string] $What)
    $p = [pscustomobject]@{ Title = 'Systémová instalační úloha neodpověděla'; What = $What; Tried = 'Okno úlohu několikrát spustilo a čekalo na odpověď.'
        Check = @('Restartujte počítač (úloha se při startu obnoví) a zkuste to znovu.', 'Když chyba trvá, kontaktujte IT – na PC chybí nebo nefunguje úloha InstalaceProgramu-Broker (GPO).') }
    foreach ($e in $Plan) {
        if ($DoneIds -contains $e.Item.Id) { continue }
        $Queue.Enqueue([pscustomobject]@{ Kind = 'result'; Result = [pscustomobject]@{ Id = $e.Item.Id; Name = $e.Item.Name; Result = 'Failed'; Source = $e.Source; Version = $e.Version; Scope = $e.Scope; ExitCode = $null; Message = $What; Problem = $p; Seconds = 0 } })
    }
    $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Results = @() })
}

function Invoke-IpBrokerRequest {
    <#
    .SYNOPSIS
        Okno -> systémová úloha. Zapíše požadavek, spustí úlohu a události z ní předává do fronty okna.
    #>
    param([Parameter(Mandatory)] [object[]] $Plan, [Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Queue, $State)
    $paths = Get-IpBrokerPaths $Settings
    $id = [guid]::NewGuid().ToString('N')
    $req = [ordered]@{
        Id = $id; Created = (Get-Date).ToString('o')
        Items = @($Plan | ForEach-Object { [ordered]@{ Id = $_.Item.Id; Version = $(if ($_.Source -eq 'nas') { [string]$_.Version } else { '' }); Scope = [string]$_.Scope } })
    }
    $reqFile = Join-Path $paths.Requests "$id.json"
    $cancelFile = Join-Path $paths.Requests "$id.cancel"
    $statusFile = Join-Path $paths.Status "$id.jsonl"
    try { [IO.File]::WriteAllText($reqFile, ($req | ConvertTo-Json -Depth 4), $script:Utf8) }
    catch { Send-IpBrokerFailure -Plan $Plan -Queue $Queue -What "Požadavek nejde předat systémové úloze: $($_.Exception.Message)"; return }
    Send-IpEvent -Queue $Queue -Data @{ Kind = 'log'; Level = 'Info'; Message = "Požadavek $id předán systémové úloze (instaluje SYSTEM, bez dotazu na heslo)." }

    $offset = [long]0; $runs = 0; $lastRun = $null; $started = $false; $idleSince = $null; $waitNote = $false; $cancelSent = $false
    $done = New-Object System.Collections.Generic.List[string]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($State -and $State['Cancel'] -and -not $cancelSent) {
            try { [IO.File]::WriteAllText($cancelFile, 'cancel', $script:Utf8) } catch { }
            $cancelSent = $true
        }
        $lines = @(Read-IpStatusLines -Path $statusFile -Offset ([ref]$offset))
        foreach ($l in $lines) {
            try { $m = $l | ConvertFrom-Json } catch { continue }
            $started = $true; $idleSince = $null
            if ($m.Kind -eq 'result' -and $m.Result) { $done.Add([string]$m.Result.Id) }
            $Queue.Enqueue($m)
            if ($m.Kind -eq 'done') { return }
        }
        $task = Get-IpBrokerTask -Settings $Settings
        $alive = $task -and $task.State -in @(2, 4)   # 2 = ve frontě, 4 = běží
        if (-not $started) {
            if ($alive) {
                if (-not $waitNote -and $sw.Elapsed.TotalSeconds -gt 10) {
                    $waitNote = $true
                    Send-IpEvent -Queue $Queue -Data @{ Kind = 'log'; Level = 'Info'; Message = 'Systémová úloha ještě dokončuje předchozí instalaci – čekám.' }
                }
            }
            elseif ($runs -lt 3 -and (-not $lastRun -or ((Get-Date) - $lastRun).TotalSeconds -gt 10)) {
                try { [void]$task.Run($null) } catch { }
                $runs++; $lastRun = Get-Date
            }
            elseif ($runs -ge 3 -and ((Get-Date) - $lastRun).TotalSeconds -gt 30) {
                Remove-Item -LiteralPath $reqFile -Force -ErrorAction SilentlyContinue
                Send-IpBrokerFailure -Plan $Plan -Queue $Queue -DoneIds $done -What 'Systémová úloha se nespustila nebo požadavek nepřevzala.'
                return
            }
        }
        elseif (-not $alive) {
            if (-not $idleSince) { $idleSince = Get-Date }
            elseif (((Get-Date) - $idleSince).TotalSeconds -gt 20) {
                Send-IpBrokerFailure -Plan $Plan -Queue $Queue -DoneIds $done -What 'Systémová úloha skončila dřív, než instalaci dokončila (podrobnosti v logu v C:\ProgramData\InstalaceProgramu\Logs).'
                return
            }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-IpBrokerLanguageRequest {
    <#
    .SYNOPSIS
        Okno -> systémová úloha: nastavit jazyk uživatelům (Changes = @{ Sid; Language }) a případně celému PC.
        Úloha si účty a cesty k profilům zjistí sama, z okna bere jen SID a ID jazyka. Události předává do fronty.
    #>
    param([Parameter(Mandatory)] $Settings, [object[]] $Changes = @(), [string[]] $Parts, $Machine, [Parameter(Mandatory)] $Queue, [Collections.IDictionary] $Body)
    $paths = Get-IpBrokerPaths $Settings
    $id = [guid]::NewGuid().ToString('N')
    $fail = { param($m) $Queue.Enqueue([pscustomobject]@{ Kind = 'langlog'; Level = 'Error'; Message = $m }); $Queue.Enqueue([pscustomobject]@{ Kind = 'langdone'; Results = @([pscustomobject]@{ Sid = ''; Account = ''; Language = ''; State = 'err'; Message = $m }); Reboot = $false; Relogon = $false }) }
    $reqFile = Join-Path $paths.Requests "$id.json"
    $statusFile = Join-Path $paths.Status "$id.jsonl"
    if ($Body) {
        # jiný druh požadavku se stejným průběhem (mazání profilů)
        $req = [ordered]@{ Id = $id; Created = (Get-Date).ToString('o') }; foreach ($k in $Body.Keys) { $req[$k] = $Body[$k] }
    }
    else {
        $req = [ordered]@{
            Id = $id; Kind = 'language'; Created = (Get-Date).ToString('o'); Parts = @($Parts)
            Changes = @($Changes | ForEach-Object { [ordered]@{ Sid = [string]$_.Sid; Language = [string]$_.Language } })
            Machine = [ordered]@{ SystemLocale = [string](Get-IpValue $Machine 'SystemLocale' ''); TimeZone = [string](Get-IpValue $Machine 'TimeZone' '') }
        }
    }
    try { [IO.File]::WriteAllText($reqFile, ($req | ConvertTo-Json -Depth 3), $script:Utf8) }
    catch { & $fail "Požadavek nejde předat systémové úloze: $($_.Exception.Message)"; return }
    $Queue.Enqueue([pscustomobject]@{ Kind = 'langlog'; Level = 'Info'; Message = 'Požadavek předán systémové úloze (bez dotazu na heslo)…' })
    $offset = [long]0; $runs = 0; $lastRun = $null; $started = $false; $idleSince = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt 60) {
        foreach ($l in @(Read-IpStatusLines -Path $statusFile -Offset ([ref]$offset))) {
            try { $m = $l | ConvertFrom-Json } catch { continue }
            $started = $true; $idleSince = $null
            if ($m.Kind -eq 'log') { $m = [pscustomobject]@{ Kind = 'langlog'; Level = $m.Level; Message = $m.Message } }
            if ($m.Kind -eq 'done') { & $fail 'Systémová úloha požadavek nedokončila (podrobnosti v logu v C:\ProgramData\InstalaceProgramu\Logs).'; return }
            $Queue.Enqueue($m)
            if ($m.Kind -eq 'langdone') { return }
        }
        $task = Get-IpBrokerTask -Settings $Settings
        $alive = $task -and $task.State -in @(2, 4)
        if (-not $started -and -not $alive) {
            if ($runs -lt 3 -and (-not $lastRun -or ((Get-Date) - $lastRun).TotalSeconds -gt 10)) { try { [void]$task.Run($null) } catch { }; $runs++; $lastRun = Get-Date }
            elseif ($runs -ge 3 -and ((Get-Date) - $lastRun).TotalSeconds -gt 30) {
                Remove-Item -LiteralPath $reqFile -Force -ErrorAction SilentlyContinue
                & $fail 'Systémová úloha se nespustila nebo požadavek nepřevzala. Restartujte počítač, nebo kontaktujte IT.'; return
            }
        }
        elseif ($started -and -not $alive) {
            if (-not $idleSince) { $idleSince = Get-Date }
            elseif (((Get-Date) - $idleSince).TotalSeconds -gt 20) { & $fail 'Systémová úloha skončila dřív, než nastavení dokončila.'; return }
        }
        Start-Sleep -Milliseconds 500
    }
    & $fail 'Systémová úloha neodpověděla do 60 minut.'
}

#endregion

#region Strana úlohy (běží jako SYSTEM)

function New-IpStatusWriter {
    # Objekt s metodou Enqueue – instalační jádro ho používá stejně jako frontu okna.
    # Při každé události zkontroluje, zda uživatel nepožádal o zastavení.
    param([string] $Path, [string] $CancelPath, $State)
    $o = [pscustomobject]@{ Path = $Path; CancelPath = $CancelPath; State = $State; Enc = $script:Utf8 }
    $o | Add-Member -MemberType ScriptMethod -Name Enqueue -Value {
        param($e)
        if ($this.CancelPath -and (Test-Path -LiteralPath $this.CancelPath)) { $this.State['Cancel'] = $true }
        try { [IO.File]::AppendAllText($this.Path, (($e | ConvertTo-Json -Depth 6 -Compress) + "`n"), $this.Enc) } catch { }
    }
    return $o
}

function Get-IpRequestUser {
    # Pro koho instalovat »jen pro uživatele«: vlastník souboru s požadavkem (ten, kdo ho založil).
    param([string] $Sid)
    if (-not $Sid -or $Sid -in @('S-1-5-18', 'S-1-5-32-544')) { return Get-IpLoggedOnUser }
    try {
        $name = (New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value
        $prof = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $prof) { return $null }
        return [pscustomobject]@{ Name = $name; Short = ($name -split '\\')[-1]; Sid = $Sid; ProfilePath = $prof }
    } catch { return $null }
}

function Invoke-IpBroker {
    <#
    .SYNOPSIS
        Zpracuje všechny čekající požadavky. Spouští ji systémová úloha (InstalaceProgramu.ps1 -Broker).
    #>
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Catalog)
    $Settings.NoInteractive = $true
    $paths = Get-IpBrokerPaths $Settings
    [void](Initialize-IpSecureDirectory -Path $paths.Status)
    Assert-IpTrustedDirectory -Path $paths.Requests
    $mutex = New-Object Threading.Mutex($false, 'Global\InstalaceProgramu-Broker')
    try { [void]$mutex.WaitOne() } catch [Threading.AbandonedMutexException] { }
    try {
        Get-ChildItem -LiteralPath $paths.Status -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-2) | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $paths.Requests -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddHours(-12) | Remove-Item -Force -ErrorAction SilentlyContinue
        $index = $null; $indexAt = $null
        while ($true) {
            $next = Get-ChildItem -LiteralPath $paths.Requests -Filter *.json -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match '^[0-9a-f]{32}$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Sort-Object LastWriteTime | Select-Object -First 1
            if (-not $next) { break }
            $id = $next.BaseName
            $sid = try { (Get-Acl -LiteralPath $next.FullName).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { '' }
            $raw = try { [IO.File]::ReadAllText($next.FullName, [Text.Encoding]::UTF8) } catch { '' }
            Remove-Item -LiteralPath $next.FullName -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $next.FullName) { break }   # nejde smazat – radši skončit než zpracovávat dokola

            $cancel = Join-Path $paths.Requests "$id.cancel"
            $state = [hashtable]::Synchronized(@{ Cancel = $false })
            $q = New-IpStatusWriter -Path (Join-Path $paths.Status "$id.jsonl") -CancelPath $cancel -State $state
            try {
                $peek = try { $raw | ConvertFrom-Json } catch { $null }
                if ($peek -and [string](Get-IpValue $peek 'Kind' '') -eq 'language') {
                    Invoke-IpBrokerLanguageJob -Req $peek -Sid $sid -Id $id -Settings $Settings -Queue $q
                    continue
                }
                if ($peek -and [string](Get-IpValue $peek 'Kind' '') -eq 'profiles') {
                    Invoke-IpBrokerProfileJob -Req $peek -Sid $sid -Id $id -Settings $Settings -Queue $q
                    continue
                }
                if (-not $index -or ((Get-Date) - $indexAt).TotalMinutes -gt 10) {
                    Send-IpEvent -Queue $q -Data @{ Kind = 'log'; Level = 'Info'; Message = 'Systémová úloha převzala požadavek, ověřuji NAS a internet…' }
                    $nas = Test-IpNas -Settings $Settings; $net = Test-IpInternet -Settings $Settings
                    $index = if ($nas.Ok) { Invoke-IpNasScan -Settings $Settings -Catalog $Catalog } else { $c = Read-IpIndexCache -Path $Settings.IndexPath; if ($c) { $x = ConvertFrom-IpIndexJson $c; $x.FromCache = $true; $x } }
                    $indexAt = Get-Date; $winget = Find-IpWinget
                }
                Invoke-IpBrokerJob -Raw $raw -Sid $sid -Id $id -Settings $Settings -Catalog $Catalog -Index $index -Nas $nas -Net $net -Winget $winget -Queue $q -State $state
            }
            catch {
                Write-IpLog -Settings $Settings -Level Error -Message "Požadavek $id selhal: $($_.Exception.Message)"
                Send-IpEvent -Queue $q -Data @{ Kind = 'log'; Level = 'Error'; Message = "Systémová úloha: $($_.Exception.Message)" }
                Send-IpEvent -Queue $q -Data @{ Kind = 'done'; Results = @() }
            }
            finally { Remove-Item -LiteralPath $cancel -Force -ErrorAction SilentlyContinue }
        }
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Invoke-IpBrokerJob {
    # Jeden požadavek: ověření vstupu, vlastní plán, instalace. Z požadavku se bere jen ID, verze a rozsah.
    param([string] $Raw, [string] $Sid, [string] $Id, $Settings, $Catalog, $Index, $Nas, $Net, [string] $Winget, $Queue, $State)
    $req = try { $Raw | ConvertFrom-Json } catch { $null }
    if (-not $req -or -not $req.Items) { throw 'Neplatný požadavek.' }
    $user = Get-IpRequestUser -Sid $Sid
    Write-IpLog -Settings $Settings -Message "=== Požadavek $Id od $(if ($user) { $user.Name } else { $Sid }) ==="
    $lang = if ($user) { Get-IpInstallLanguage -Map (Read-IpLanguageAssignments -Settings $Settings) -Sid $user.Sid } else { '' }
    $ctx = @{ NasOk = [bool]$Nas.Ok; NetOk = [bool]$Net.Ok; Winget = $Winget; User = $user; Lang = $lang }
    $plan = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($ri in @($req.Items | Select-Object -First 200)) {
        $iid = [string]$ri.Id
        if ($seen.ContainsKey($iid)) { continue }; $seen[$iid] = 1
        $it = if ($iid -match '^[\w.-]{1,64}$' -and $Catalog.ById.ContainsKey($iid)) { $Catalog.ById[$iid] } else { $null }
        $fail = $null
        if (-not $it) { $fail = 'Program není v katalogu. Ruční výjimky z okna Obsah NAS bez práv správce instalovat nejde – nainstaluje je IT.' }
        else {
            $scope = if ([string]$ri.Scope -in @('all', 'user')) { [string]$ri.Scope } else { '' }
            $ver = if ([string]$ri.Version -match '^[\w.,\- ]{0,64}$') { [string]$ri.Version } else { '' }
            $pe = Resolve-IpPlanEntry -Item $it -Index $Index -Ctx $ctx -Version $ver -Scope $scope
            if ($pe.Ok) { $plan.Add($pe) } else { $fail = $pe.Reason }
        }
        if ($fail) {
            $name = if ($it) { $it.Name } else { $iid }
            $p = [pscustomobject]@{ Title = "$name se nenainstaluje"; What = "$fail."; Tried = 'Systémová úloha ověřila NAS i internet.'; Check = @('Ověřte připojení k NAS a internetu a klikněte na Zkusit znovu.') }
            Send-IpEvent -Queue $Queue -Data @{ Kind = 'result'; Result = [pscustomobject]@{ Id = $iid; Name = $name; Result = 'Failed'; Source = ''; Version = ''; Scope = ''; ExitCode = $null; Message = $fail; Problem = $p; Seconds = 0 } }
        }
    }
    if (-not $plan.Count) { Send-IpEvent -Queue $Queue -Data @{ Kind = 'done'; Results = @() }; return }
    [void](Invoke-IpInstallBatch -Plan $plan.ToArray() -Ctx $ctx -Settings $Settings -Queue $Queue -State $State)
}

function Invoke-IpBrokerLanguageJob {
    # Požadavek na jazyk od uživatele bez práv správce. S languageForAll (výchozí) smí nastavit komukoli
    # i celému PC, jinak jen sám sobě (vlastník souboru s požadavkem). Z požadavku se bere jen SID
    # a ID jazyka / hodnoty z languages.json – účet a cestu k profilu si úloha zjistí sama.
    param($Req, [string] $Sid, [string] $Id, $Settings, $Queue)
    $user = Get-IpRequestUser -Sid $Sid
    if (-not $user -or -not $user.Sid) { throw 'Nejde zjistit, kdo požadavek poslal.' }
    $langs = Read-IpLanguages -Settings $Settings
    $all = [bool]$Settings.LanguageForAll
    $parts = @(@(Get-IpValue $Req 'Parts' @()) | ForEach-Object { [string]$_ } | Where-Object { $_ -in @('keyboard', 'ui', 'region') })
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($c in @(@(Get-IpValue $Req 'Changes' @()) | Select-Object -First 200)) {
        $tsid = [string](Get-IpValue $c 'Sid' ''); $lang = [string](Get-IpValue $c 'Language' '')
        if ($lang -and -not $langs.ById.ContainsKey($lang)) { throw "Jazyk '$lang' není v languages.json." }
        if (-not $all -and $tsid -ne $user.Sid) { throw 'Jazyk ostatním uživatelům a celému PC nastaví jen IT (v settings.json je languageForAll vypnuté).' }
        if ($tsid -eq 'default') { $changes.Add(@{ Sid = 'default'; Account = 'default'; ProfilePath = ''; Language = $lang }); continue }
        if ($tsid -notmatch '^S-1-(5-21|12-1)-[\d-]+$') { throw 'Neplatný účet v požadavku.' }
        $acc = Resolve-IpAccount -Name $tsid
        $changes.Add(@{ Sid = $tsid; Account = $acc.Name; ProfilePath = $acc.ProfilePath; Language = $lang })
    }
    $machine = @{ SystemLocale = ''; TimeZone = '' }
    $m = Get-IpValue $Req 'Machine' $null
    if ($m) {
        $sl = [string](Get-IpValue $m 'SystemLocale' ''); $tz = [string](Get-IpValue $m 'TimeZone' '')
        if (($sl -or $tz) -and -not $all) { throw 'Nastavení celého PC smí měnit jen IT (v settings.json je languageForAll vypnuté).' }
        if ($sl -and @($langs.Items | ForEach-Object SystemLocale) -notcontains $sl) { throw "Jazyk systému '$sl' není v languages.json." }
        if ($tz -and @($langs.Items | ForEach-Object TimeZone | Where-Object { $_ }) -notcontains $tz) { throw "Časové pásmo '$tz' není v languages.json." }
        $machine = @{ SystemLocale = $sl; TimeZone = $tz }
    }
    if (-not $changes.Count -and -not ($machine.SystemLocale -or $machine.TimeZone)) { throw 'Požadavek nic nemění.' }
    Write-IpLog -Settings $Settings -Message ("=== Požadavek $Id (jazyk) od $($user.Name): " + (($changes | ForEach-Object { "$($_.Account)=$(if ($_.Language) { $_.Language } else { 'zrušit' })" }) -join ', ') + " · PC: $($machine.SystemLocale) $($machine.TimeZone) ===")
    Send-IpEvent -Queue $Queue -Data @{ Kind = 'langlog'; Level = 'Info'; Message = "Systémová úloha převzala požadavek na jazyk (od $($user.Name))." }
    [void](Invoke-IpLanguageChanges -Settings $Settings -Changes $changes.ToArray() -Parts $parts -Machine $machine -Queue $Queue)
}

function Invoke-IpBrokerProfileJob {
    # Smazání profilů od uživatele bez práv správce – jen když to settings.json dovolí (profileDeleteForAll).
    # Vlastní účet žadatele a přihlášení uživatelé jsou vždy chránění.
    param($Req, [string] $Sid, [string] $Id, $Settings, $Queue)
    if (-not $Settings.ProfileDeleteForAll) { throw 'Mazání účtů bez práv správce není povolené (v settings.json je profileDeleteForAll vypnuté). Smaže je IT.' }
    $user = Get-IpRequestUser -Sid $Sid
    if (-not $user -or -not $user.Sid) { throw 'Nejde zjistit, kdo požadavek poslal.' }
    $targets = @(@(Get-IpValue $Req 'Targets' @()) | Select-Object -First 100 | ForEach-Object { @{ Sid = [string](Get-IpValue $_ 'Sid' ''); DeleteAccount = [bool](Get-IpValue $_ 'DeleteAccount' $false) } })
    if (-not $targets.Count) { throw 'Požadavek nic nemaže.' }
    Write-IpLog -Settings $Settings -Message "=== Požadavek $Id (mazání profilů) od $($user.Name): $(($targets | ForEach-Object Sid) -join ', ') ==="
    Send-IpEvent -Queue $Queue -Data @{ Kind = 'langlog'; Level = 'Info'; Message = "Systémová úloha převzala požadavek na smazání (od $($user.Name))." }
    [void](Remove-IpUserProfiles -Settings $Settings -Targets $targets -Protect @($user.Sid) -Queue $Queue)
}

#endregion

Export-ModuleMember -Function @(
    'Get-IpBrokerPaths', 'Get-IpBrokerTask', 'Test-IpBroker', 'Register-IpBroker', 'Invoke-IpBrokerRequest', 'Invoke-IpBroker', 'Invoke-IpBrokerLanguageRequest'
)
