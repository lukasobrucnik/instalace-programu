#Requires -Version 5.1
<#
.SYNOPSIS
    Grafické rozhraní (WPF): úvodní kontrola, hlavní okno ve třech krocích, okno Stav a návod,
    Obsah NAS s výjimkami pro tuto relaci, průběh instalace.
.NOTES
    Kontroly a instalace běží v samostatných runspace na pozadí, okno nezamrzá.
    Výsledky chodí přes frontu událostí, kterou čte DispatcherTimer v UI vlákně.
    Každá obsluha události je obalená Invoke-IpSafe – chyba se zapíše do logu a ukáže,
    ale okno nespadne (poučení ze vzoru sw-install 1.0.3).
    Pozor: v řetězcích v uvozovkách "" nepoužívat české „“ – PowerShell je bere jako konec řetězce.
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'NasIndex.psm1')
Import-Module (Join-Path $PSScriptRoot 'Health.psm1')
Import-Module (Join-Path $PSScriptRoot 'Install.psm1')
Import-Module (Join-Path $PSScriptRoot 'Language.psm1')
Import-Module (Join-Path $PSScriptRoot 'Broker.psm1')

$script:S = $null
$script:C = @{}
$script:BrushCache = @{}
$script:Col = @{
    Accent = '#0A6672'; AccentSoft = '#D8EDEF'; Bg = '#E8EDEF'; Surface = '#FFFFFF'; Surface2 = '#F3F6F7'; Line = '#D3DCDF'; Line2 = '#E5EAEC'
    Fg = '#13232A'; Muted = '#56676E'; Ok = '#1B7443'; OkSoft = '#DBF0E2'; Warn = '#9A5600'; WarnSoft = '#F8E9D1'; Err = '#B3261E'; ErrSoft = '#F8E0DD'
    LedOk = '#3DDC84'; LedWarn = '#FFA53B'; LedErr = '#FF4D42'; HdFg = '#DBE6E8'; HdMuted = '#93A9AF'
}
$script:ExCategory = 'Ručně povolené z NAS'

#region Pomocné funkce pro prvky WPF

function Get-IpBrush { param([string] $Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) { $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($Hex); $b.Freeze(); $script:BrushCache[$Hex] = $b }
    return $script:BrushCache[$Hex]
}
function New-IpText {
    param([string] $Text, [double] $Size = 13.5, [string] $Weight = 'Normal', [string] $Color = '', [switch] $Wrap, [string] $Margin = '', [string] $Font = '')
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.FontWeight = $Weight
    if ($Color) { $t.Foreground = Get-IpBrush $Color }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    if ($Margin) { $t.Margin = $Margin }
    if ($Font) { $t.FontFamily = $Font }
    return $t
}
function New-IpPanel { param([string] $Orientation = 'Vertical', [string] $Margin = '')
    $p = New-Object Windows.Controls.StackPanel; $p.Orientation = $Orientation; if ($Margin) { $p.Margin = $Margin }; return $p
}
function New-IpBorder {
    param($Child, [string] $Bg = '', [string] $BorderColor = '', [string] $Thickness = '0', [double] $Radius = 0, [string] $Padding = '', [string] $Margin = '')
    $b = New-Object Windows.Controls.Border
    if ($Bg) { $b.Background = Get-IpBrush $Bg }
    if ($BorderColor) { $b.BorderBrush = Get-IpBrush $BorderColor; $b.BorderThickness = $Thickness }
    $b.CornerRadius = $Radius
    if ($Padding) { $b.Padding = $Padding }
    if ($Margin) { $b.Margin = $Margin }
    if ($Child) { $b.Child = $Child }
    return $b
}
function New-IpChip { param([string] $Text, [string] $Fg, [string] $Bg, [string] $Tip = '')
    $b = New-IpBorder -Child (New-IpText $Text 11 'SemiBold' $Fg) -Bg $Bg -Radius 9 -Padding '7,1' -Margin '0,0,6,0'
    $b.HorizontalAlignment = 'Left'; $b.VerticalAlignment = 'Center'
    if ($Tip) { $b.ToolTip = $Tip }
    return $b
}
function New-IpButton { param([string] $Text, [string] $Style = 'Btn', $Tag = $null, [string] $Margin = '', [string] $Padding = '')
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text; $b.Style = $script:S.Win.FindResource($Style); $b.Tag = $Tag
    if ($Margin) { $b.Margin = $Margin }
    if ($Padding) { $b.Padding = $Padding }
    return $b
}
function New-IpStateIcon { param([string] $State, [double] $Size = 26)
    $map = @{ ok = @('✓', $script:Col.Ok, $script:Col.OkSoft); warn = @('!', $script:Col.Warn, $script:Col.WarnSoft); err = @('✕', $script:Col.Err, $script:Col.ErrSoft)
        run = @('…', $script:Col.Accent, $script:Col.AccentSoft); info = @('i', $script:Col.Accent, $script:Col.AccentSoft); na = @('–', $script:Col.Muted, $script:Col.Surface2) }
    $m = $map[$State]; if (-not $m) { $m = $map['na'] }
    $t = New-IpText $m[0] ($Size * 0.5) 'Bold' $m[1]; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b = New-IpBorder -Child $t -Bg $m[2] -Radius ($Size / 2); $b.Width = $Size; $b.Height = $Size; $b.VerticalAlignment = 'Top'
    return $b
}
function Get-IpPlural { param([int] $N, [string] $One, [string] $Few, [string] $Many)
    if ($N -eq 1) { return $One } if ($N -gt 1 -and $N -lt 5) { return $Few } return $Many
}

function Invoke-IpSafe {
    param([Parameter(Mandatory)] [scriptblock] $Script)
    try { & $Script } catch { Write-IpUiError $_ }
}
function Write-IpUiError { param($Err)
    $msg = if ($Err -is [Management.Automation.ErrorRecord]) { "$($Err.Exception.Message) ($($Err.InvocationInfo.PositionMessage -replace '\s+', ' '))" } else { "$Err" }
    try { Write-IpLog -Settings $script:S.Settings -Level Error -Message "Chyba okna: $msg" } catch { }
    $short = ($msg -split ' \(At ')[0]
    try { Show-IpToast ('Nastala chyba, okno pokračuje dál: ' + $short) } catch { }
}

$script:ToastTimer = $null
function Show-IpToast { param([string] $Text)
    $script:C.ToastText.Text = $Text; $script:C.Toast.Visibility = 'Visible'
    if (-not $script:ToastTimer) {
        $script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
        $script:ToastTimer.Interval = [TimeSpan]::FromSeconds(5)
        $script:ToastTimer.Add_Tick({ $script:C.Toast.Visibility = 'Collapsed'; $script:ToastTimer.Stop() })
    }
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
}

#endregion

#region Stav a výpočty

function Get-IpAllItems { return @($script:S.Catalog.Items) + @($script:S.Allowed.Values) }
function Get-IpHealthCheck { param([string] $Key) return @($script:S.Health | Where-Object Key -eq $Key) | Select-Object -First 1 }
function Get-IpState { param([string] $Key) $c = Get-IpHealthCheck $Key; if ($c) { return $c.State } return 'na' }

function Get-IpCtx {
    return @{
        NasOk = (Get-IpState 'nas') -ne 'err' -and (Get-IpState 'nas') -ne 'na'
        NetOk = (Get-IpState 'inet') -ne 'err' -and (Get-IpState 'inet') -ne 'na'
        Winget = $script:S.Winget; User = $script:S.User
        Lang = $(if ($script:S.User) { Get-IpInstallLanguage -Map $script:S.LangAssign -Sid $script:S.User.Sid } else { '' })
    }
}
function Get-IpScopeOf { param($Item)
    if ($Item.Scope -eq 'machine') { return 'all' }
    if ($script:S.Scope.ContainsKey($Item.Id)) { return $script:S.Scope[$Item.Id] }
    if ($script:S.Mode -eq 'all') { return 'all' }
    if ($script:S.Mode -eq 'user' -and $script:S.User) { return 'user' }
    if ($Item.Recommended -eq 'user' -and -not $script:S.User) { return 'all' }
    return $Item.Recommended
}
function Get-IpPlan { param($Item)
    $v = if ($script:S.Ver.ContainsKey($Item.Id)) { $script:S.Ver[$Item.Id] } else { '' }
    return Resolve-IpPlanEntry -Item $Item -Index $script:S.Index -Ctx (Get-IpCtx) -Version $v -Scope (Get-IpScopeOf $Item)
}
function Get-IpStatusText { param($Item)
    if ($Item.Exception) { return @('miss', 'ruční výjimka') }
    $st = $script:S.Installed[$Item.Id]
    if (-not $st -or -not $st.Installed) { return @('miss', 'Chybí') }
    $rec = @(Get-IpCandidates -Index $script:S.Index -ItemId $Item.Id | Where-Object Recommended) | Select-Object -First 1
    $v = if ($st.Version) { " $($st.Version)" } else { '' }
    if ($rec -and $st.Version -and $rec.Version -notmatch '^\d{4}-' -and (Compare-IpVersion $rec.Version $st.Version) -gt 0) { return @('upd', "Má$v · na NAS novější") }
    $who = if ($st.Scope -eq 'user') { ' (jen uživatel)' } else { '' }
    return @('ok', "Nainstalováno$v$who")
}
function Test-IpBusy { return [bool]($script:S.Run -and -not $script:S.Run.Done) }
function Get-IpSelected { return @(Get-IpAllItems | Where-Object { $script:S.Sel.Contains($_.Id) }) }

#endregion

#region Úlohy na pozadí

function Start-IpJob {
    param([Parameter(Mandatory)] [string] $Kind, [Parameter(Mandatory)] [scriptblock] $Script, [hashtable] $Params = @{})
    $iss = [initialsessionstate]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $iss.ImportPSModule(@('Common', 'NasIndex', 'Health', 'Install', 'Language', 'Broker' | ForEach-Object { Join-Path $script:S.SrcDir "$_.psm1" }))
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.ApartmentState = 'STA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    [void]$script:S.Jobs.Add([pscustomobject]@{ Kind = $Kind; PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() })
}

$script:HealthJob = {
    param($Settings, $Catalog, $Queue, [bool] $Rescan, $OldIndex, [bool] $Broker)
    $user = Get-IpLoggedOnUser
    $winget = Find-IpWinget
    $nas = Test-IpNas -Settings $Settings
    $net = Test-IpInternet -Settings $Settings
    $index = $OldIndex
    if ($Rescan -or -not $index) {
        if ($nas.Ok) { $index = Invoke-IpNasScan -Settings $Settings -Catalog $Catalog -Queue $Queue }
        else {
            $c = Read-IpIndexCache -Path $Settings.IndexPath
            if ($c) { $index = ConvertFrom-IpIndexJson $c; $index.FromCache = $true }
        }
    }
    elseif ($index -and -not $nas.Ok) { $index.FromCache = $true }
    $installed = Get-IpInstalledState -Items $Catalog.Items -User $user
    $health = Get-IpHealth -Settings $Settings -Catalog $Catalog -Index $index -Nas $nas -Net $net -User $user -WingetPath $winget -Broker $Broker
    $Queue.Enqueue([pscustomobject]@{ Kind = 'health'; User = $user; Winget = $winget; Index = $index; Installed = $installed; Health = $health })
}

function Start-IpHealthCheck { param([bool] $Rescan = $true)
    if (@($script:S.Jobs | Where-Object Kind -eq 'health').Count) { return }
    $script:S.Checking = $true
    if ($Rescan) { $script:S.ScanMsg = 'Ověřuji NAS, internet a obsah NAS…' }
    Update-IpAll
    Start-IpJob -Kind 'health' -Script $script:HealthJob -Params @{ Settings = $script:S.Settings; Catalog = $script:S.Catalog; Queue = $script:S.Queue; Rescan = $Rescan; OldIndex = $(if ($Rescan) { $null } else { $script:S.Index }); Broker = [bool]$script:S.UseBroker }
}

$script:InstallJob = {
    param($Plan, $Ctx, $Settings, $Queue, $State)
    [void](Invoke-IpInstallBatch -Plan $Plan -Ctx $Ctx -Settings $Settings -Queue $Queue -State $State)
}

# Bez práv správce: instalaci provede systémová úloha, okno jen předává události.
$script:BrokerJob = {
    param($Plan, $Settings, $Queue, $State)
    Invoke-IpBrokerRequest -Plan $Plan -Settings $Settings -Queue $Queue -State $State
}

function Complete-IpJobs {
    foreach ($j in @($script:S.Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        try {
            [void]$j.PS.EndInvoke($j.Handle)
            foreach ($e in $j.PS.Streams.Error) { Write-IpLog -Settings $script:S.Settings -Level Error -Message "Úloha $($j.Kind): $e" }
        }
        catch {
            Write-IpLog -Settings $script:S.Settings -Level Error -Message "Úloha $($j.Kind) selhala: $($_.Exception.Message)"
            Show-IpToast "Úloha na pozadí selhala: $($_.Exception.Message)"
            if ($j.Kind -eq 'health') { $script:S.Checking = $false; Update-IpAll }
            if ($j.Kind -eq 'install' -and $script:S.Run) { $script:S.Run.Done = $true; Update-IpAll }
            if ($j.Kind -like 'lang*') { $script:S.L.Busy = $false; $script:S.L.Loading = $false; $script:S.L.Searching = $false; Update-IpLangWindow }
        }
        finally { $j.PS.Dispose(); $j.RS.Dispose(); $script:S.Jobs.Remove($j) }
    }
}

function Invoke-IpPump {
    $m = $null; $n = 0; $dirty = $false; $runDirty = $false; $langDirty = $false; $whoDirty = $false
    while ($n -lt 300 -and $script:S.Queue.TryDequeue([ref]$m)) {
        $n++
        try {
            switch ($m.Kind) {
                'log' { Add-IpLogLine $m.Message }
                'scan' { $script:S.ScanMsg = $m.Message; $script:C.StartSub.Text = $m.Message }
                'health' {
                    $script:S.User = $m.User; $script:S.Winget = $m.Winget; $script:S.Index = $m.Index
                    $script:S.Installed = $m.Installed; $script:S.Health = @($m.Health); $script:S.Checking = $false
                    $script:S.CheckedAt = Get-Date; $dirty = $true
                    if ($env:IP_DEBUG -and -not $script:S.DebugDone) { $script:S.DebugDone = $true; [void]$script:S.Win.Dispatcher.BeginInvoke([Action] { Invoke-IpSafe { Invoke-IpDebugView } }) }
                }
                'item' {
                    $r = $script:S.Run; if ($r) { $e = $r.Entries | Where-Object Id -eq $m.Id | Select-Object -First 1
                        if ($e) { $e.Status = $m.Status; $e.Msg = $m.Message }; $runDirty = $true }
                }
                'result' {
                    $r = $script:S.Run; $res = $m.Result
                    if ($r) {
                        $e = $r.Entries | Where-Object Id -eq $res.Id | Select-Object -First 1
                        if ($e) {
                            $e.Status = switch ($res.Result) { 'Success' { 'ok' } 'Reboot' { 'ok' } 'Manual' { 'ok' } 'Skipped' { 'skip' } 'Cancelled' { 'cancel' } default { 'err' } }
                            $e.Msg = if ($res.Result -eq 'Failed') { $res.Message } else { $res.Message }
                            $e.Result = $res
                        }
                        if ($res.Result -eq 'Reboot') { $r.Reboot = $true }
                        $runDirty = $true
                    }
                }
                'dialog' { if ($script:S.Run) { $script:S.Run.Dialogs.Add($m); $runDirty = $true; Show-IpToast "Instalátor zobrazil okno »$($m.Title)«. Pokud čeká na odpověď, dokončete ho." } }
                'interactive' {
                    if ($m.On) { Show-IpToast 'Otevřelo se okno instalátoru – dokončete ho. Toto okno se zatím zmenšilo.'; $script:S.Win.WindowState = 'Minimized' }
                    else { $script:S.Win.WindowState = 'Maximized'; $script:S.Win.Activate() | Out-Null }
                }
                'done' { if ($script:S.Run) { $script:S.Run.Done = $true; $runDirty = $true; Start-IpHealthCheck -Rescan $false } }
                'langusers' {
                    $L = $script:S.L; $L.Loading = $false; $L.Error = [string]$m.Error
                    if ($m.Languages) { $L.Data = $m; $script:S.Langs = $m.Languages; $script:S.LangAssign = $m.Assign }
                    $langDirty = $true; $whoDirty = $true
                }
                'langfound' { $L = $script:S.L; $L.Searching = $false; $L.Found = @($m.Users); $L.FindError = [string]$m.Error; $langDirty = $true }
                'langlog' { [void]$script:S.L.Log.Add($m); Add-IpLogLine "Jazyk: $($m.Message)"; $langDirty = $true }
                'langdone' {
                    $L = $script:S.L; $L.Busy = $false; $L.Del.Clear()
                    # výsledek smazání + následného uložení jazyka zobrazit dohromady
                    if ($L.PrevDone) { $m = [pscustomobject]@{ Kind = 'langdone'; Results = @(@($L.PrevDone.Results) + @($m.Results)); Reboot = $m.Reboot; Relogon = $m.Relogon }; $L.PrevDone = $null }
                    $L.Done = $m
                    $chain = [bool]$L.ThenSave; $L.ThenSave = $false
                    if ($chain) { Save-IpLanguage -KeepLog }
                    if (-not $L.Busy) {
                        $L.Pending = @{}; $L.MachineSel = @{ SystemLocale = ''; TimeZone = '' }; $L.Extra = [ordered]@{}; $L.Found = @()
                        $bad = @($m.Results | Where-Object { $_.State -eq 'err' }).Count
                        Show-IpToast $(if ($bad) { "$bad $(Get-IpPlural $bad 'chyba' 'chyby' 'chyb') – podrobnosti v okně Jazyk uživatelů." } else { 'Hotovo.' })
                        Start-IpLangLoad
                    }
                    $langDirty = $true
                }
            }
        }
        catch { Write-IpUiError $_ }
    }
    Complete-IpJobs
    if ($dirty) { Update-IpAll; if ($script:S.StatusWin) { Update-IpStatusWindow } }
    elseif ($runDirty) { Update-IpMiddle; Update-IpLeftRightEnabled }
    elseif ($whoDirty) { Update-IpBundles }
    if ($langDirty) { Update-IpLangWindow }
}

function Add-IpLogLine { param([string] $Line)
    $b = $script:C.LogBox
    $b.AppendText($Line + "`r`n")
    if ($b.LineCount -gt 3000) { $b.Text = ($b.Text -split "`r`n" | Select-Object -Last 2000) -join "`r`n" }
    $b.ScrollToEnd()
}

#endregion

#region Horní lišta a úvodní kontrola

function Update-IpHeader {
    $p = $script:C.LedPanel; $p.Children.Clear()
    foreach ($k in 'nas', 'inet', 'sophos', 'font', 'index') {
        $c = Get-IpHealthCheck $k
        $st = if ($script:S.Checking -and -not $c) { 'na' } elseif ($c) { $c.State } else { 'na' }
        $led = switch ($st) { 'ok' { $script:Col.LedOk } 'warn' { $script:Col.LedWarn } 'err' { $script:Col.LedErr } default { '#7F949A' } }
        $sp = New-IpPanel 'Horizontal'
        $e = New-Object Windows.Shapes.Ellipse; $e.Width = 10; $e.Height = 10; $e.Fill = Get-IpBrush $led; $e.Margin = '0,0,7,0'; $e.VerticalAlignment = 'Center'
        $e.Effect = New-Object Windows.Media.Effects.DropShadowEffect -Property @{ Color = ([Windows.Media.ColorConverter]::ConvertFromString($led)); BlurRadius = 8; ShadowDepth = 0; Opacity = 0.9 }
        [void]$sp.Children.Add($e)
        $label = @{ nas = 'NAS'; inet = 'Internet'; sophos = 'Sophos'; font = 'Písmo'; index = 'Index' }[$k]
        [void]$sp.Children.Add((New-IpText $label 12.5 'SemiBold' $script:Col.HdFg))
        $word = if ($c) { $c.Word } else { 'ověřuji' }
        [void]$sp.Children.Add((New-IpText " $word" 12.5 'Normal' $script:Col.HdMuted))
        [void]$sp.Children.Add((New-IpText '  ⓘ' 12.5 'Normal' '#5CC6D1'))
        $b = New-Object Windows.Controls.Button
        $b.Style = $script:S.Win.FindResource('HdBtn'); $b.Content = $sp; $b.Tag = $k; $b.Margin = '0,0,5,0'; $b.Padding = '9,4'
        $b.ToolTip = if ($c) { "$($c.Title) – klikněte pro vysvětlení a návod" } else { 'Ověřuji…' }
        $b.Add_Click({ param($s, $e) Invoke-IpSafe { Show-IpStatusWindow -Key $s.Tag } })
        [void]$p.Children.Add($b)
    }
    $ex = $script:S.Allowed.Count
    $script:C.BtnNas.Content = if ($ex) { "Obsah NAS · $ex $(Get-IpPlural $ex 'výjimka' 'výjimky' 'výjimek')" } else { 'Obsah NAS' }
}

function Update-IpStart {
    $list = $script:C.CheckList; $list.Children.Clear()
    $checks = if ($script:S.Checking -or -not $script:S.Health) {
        foreach ($k in 'admin', 'nas', 'inet', 'sophos', 'font', 'disk', 'index') {
            $old = Get-IpHealthCheck $k
            [pscustomobject]@{ Key = $k; Long = $(if ($old) { $old.Long } else { @{ admin = 'Oprávnění správce'; nas = 'Síťová cesta NAS'; inet = 'Připojení k internetu'; sophos = 'Instalátor Sophos'; font = 'Písmo Code128'; disk = 'Volné místo na disku'; index = 'Obsah NAS (index instalátorů)' }[$k] }); State = 'run'; Title = 'Ověřuji…'; Detail = ''; Steps = @() }
        }
    } else { $script:S.Health }
    foreach ($c in $checks) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '26,14,26,14'
        foreach ($w in @('32', '*', 'Auto')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
        $ic = New-IpStateIcon $c.State; [void]$g.Children.Add($ic)
        $sp = New-IpPanel; [Windows.Controls.Grid]::SetColumn($sp, 1); $sp.Margin = '10,0,10,0'
        [void]$sp.Children.Add((New-IpText $c.Long 14.5 'SemiBold'))
        $d = if ($c.State -eq 'run') { 'Ověřuji…' } else { "$($c.Title). $($c.Detail)" }
        [void]$sp.Children.Add((New-IpText $d 13 'Normal' $script:Col.Muted -Wrap -Margin '0,2,0,0'))
        if ($c.State -in @('warn', 'err') -and @($c.Steps).Count) {
            $fx = New-IpPanel
            [void]$fx.Children.Add((New-IpText 'CO UDĚLAT' 11 'SemiBold' $script:Col.Muted -Margin '0,0,0,4'))
            $i = 0; foreach ($st in $c.Steps) { $i++; [void]$fx.Children.Add((New-IpText "$i. $($st[0])" 13 'Normal' '' -Wrap)) }
            $lnk = New-IpButton 'Podrobný návod krok za krokem →' 'Link' $c.Key '0,6,0,0'; $lnk.HorizontalAlignment = 'Left'; $lnk.Padding = '0,2'
            $lnk.Add_Click({ param($s, $e) Invoke-IpSafe { Show-IpStatusWindow -Key $s.Tag } })
            [void]$fx.Children.Add($lnk)
            [void]$sp.Children.Add((New-IpBorder -Child $fx -Bg $script:Col.Surface2 -BorderColor $script:Col.Line2 -Thickness '1' -Radius 8 -Padding '14,10' -Margin '0,10,0,0'))
        }
        [void]$g.Children.Add($sp)
        $word = @{ ok = 'V POŘÁDKU'; warn = 'PROBLÉM'; err = 'NEFUNGUJE'; run = 'OVĚŘUJI'; na = '' }[$c.State]
        $col = @{ ok = $script:Col.Ok; warn = $script:Col.Warn; err = $script:Col.Err; run = $script:Col.Muted; na = $script:Col.Muted }[$c.State]
        $wt = New-IpText $word 11.5 'Bold' $col; [Windows.Controls.Grid]::SetColumn($wt, 2); $wt.Margin = '0,4,0,0'
        [void]$g.Children.Add($wt)
        [void]$list.Children.Add($g)
        [void]$list.Children.Add((New-IpBorder -BorderColor $script:Col.Line2 -Thickness '0,1,0,0'))
    }
    $block = -not $script:S.Checking -and @($script:S.Health | Where-Object { $_.Blocking -and $_.State -eq 'err' }).Count
    $warn = -not $script:S.Checking -and @($script:S.Health | Where-Object { $_.State -ne 'ok' }).Count
    $script:C.StartMsg.Text = if ($script:S.Checking) { $script:S.ScanMsg }
    elseif ($block) { 'Povinné položky se teď nenainstalují. Otevřete návod u červené položky, opravte to a zkontrolujte znovu. Nebo pokračujte – aplikace na ně upozorní před instalací i v souhrnu.' }
    elseif ($warn) { 'Můžete pokračovat. U oranžových položek je návod, jak problém odstranit.' }
    else { 'Vše je připraveno.' }
    $script:C.BtnGo.Content = if ($block) { 'Pokračovat s omezením' } else { 'Pokračovat' }
    $script:C.BtnGo.IsEnabled = -not $script:S.Checking
    $script:C.BtnRecheck.IsEnabled = -not $script:S.Checking
    $script:C.StartSub.Text = if ($script:S.Checking) { $script:S.ScanMsg } else { "$([Environment]::MachineName) · kontrola před spuštěním" + $(if ($script:S.CheckedAt) { " · $($script:S.CheckedAt.ToString('H:mm:ss'))" } else { '' }) }
}

function Set-IpPage { param([string] $Page)
    $script:S.Page = $Page
    $script:C.PageStart.Visibility = if ($Page -eq 'start') { 'Visible' } else { 'Collapsed' }
    $script:C.PageMain.Visibility = if ($Page -eq 'main') { 'Visible' } else { 'Collapsed' }
    $script:C.TabStart.IsChecked = $Page -eq 'start'; $script:C.TabMain.IsChecked = $Page -eq 'main'
}

#endregion

#region Hlavní okno – sloupec 1 (balíčky)

function Test-IpBundleChanged {
    if ($null -eq $script:S.Bundle) { return $false }
    $b = $script:S.Catalog.Bundles | Where-Object Id -eq $script:S.Bundle
    $want = @($b.Items | Where-Object { $script:S.Catalog.ById.ContainsKey($_) -and (Get-IpPlan $script:S.Catalog.ById[$_]).Ok })
    $have = @(Get-IpSelected | Where-Object { -not $_.Required } | ForEach-Object Id)
    return ($have.Count -ne $want.Count) -or @($have | Where-Object { $want -notcontains $_ }).Count
}

function Update-IpBundles {
    $p = $script:C.BundleList; $p.Children.Clear()
    $onlyReq = $null -eq $script:S.Bundle -and -not @(Get-IpSelected | Where-Object { -not $_.Required }).Count
    foreach ($b in $script:S.Catalog.Bundles) {
        $ok = @($b.Items | Where-Object { (Get-IpPlan $script:S.Catalog.ById[$_]).Ok }).Count; $miss = @($b.Items).Count - $ok
        $sp = New-IpPanel
        $hd = New-IpPanel 'Horizontal'; [void]$hd.Children.Add((New-IpText $b.Name 13.5 'SemiBold'))
        $active = $script:S.Bundle -eq $b.Id
        if ($active -and (Test-IpBundleChanged)) { [void]$hd.Children.Add((New-IpChip 'upraveno' $script:Col.Warn $script:Col.WarnSoft)) ; $hd.Children[1].Margin = '8,0,0,0' }
        [void]$sp.Children.Add($hd)
        [void]$sp.Children.Add((New-IpText $b.Description 12 'Normal' $script:Col.Muted -Wrap))
        [void]$sp.Children.Add((New-IpText ("$ok $(Get-IpPlural $ok 'program' 'programy' 'programů') + povinný základ" + $(if ($miss) { " · $miss nedostupné" } else { '' })) 11.5 'SemiBold' $script:Col.Accent -Margin '0,4,0,0'))
        $btn = New-IpButton '' 'Btn' $b.Id '0,0,0,8' '10,9'; $btn.Content = $sp; $btn.HorizontalContentAlignment = 'Stretch'; $btn.FontWeight = 'Normal'
        if ($active) { $btn.Background = Get-IpBrush $script:Col.AccentSoft; $btn.BorderBrush = Get-IpBrush $script:Col.Accent; $btn.BorderThickness = '2' }
        $btn.Add_Click({ param($s, $e) Invoke-IpSafe { Select-IpBundle $s.Tag } })
        [void]$p.Children.Add($btn)
    }
    $sp = New-IpPanel; [void]$sp.Children.Add((New-IpText 'Jen povinný základ' 13.5 'SemiBold')); [void]$sp.Children.Add((New-IpText 'Bez balíčku, programy přidáte vpravo' 12 'Normal' $script:Col.Muted -Wrap))
    $btn = New-IpButton '' 'Btn' '' '0,0,0,8' '10,9'; $btn.Content = $sp; $btn.HorizontalContentAlignment = 'Stretch'; $btn.FontWeight = 'Normal'
    $btn.Background = Get-IpBrush $(if ($onlyReq) { $script:Col.AccentSoft } else { 'Transparent' }); if ($onlyReq) { $btn.BorderBrush = Get-IpBrush $script:Col.Accent }
    $btn.Add_Click({ param($s, $e) Invoke-IpSafe { Clear-IpSelection } })
    [void]$p.Children.Add($btn)
    $u = if ($script:S.User) { $script:S.User.Name } else { 'nikdo' }
    $lg = if ($script:S.User -and $script:S.LangAssign -and $script:S.LangAssign.ContainsKey($script:S.User.Sid)) { [string]$script:S.LangAssign[$script:S.User.Sid].Name } else { 'podle Windows' }
    $script:C.WhoText.Text = "Počítač: $([Environment]::MachineName)`nPřihlášen: $u`nSpuštěno jako: $([Environment]::UserDomainName)\$([Environment]::UserName)`nJazyk instalací: $lg"
}

function Select-IpBundle { param([string] $Id)
    $b = $script:S.Catalog.Bundles | Where-Object Id -eq $Id
    $script:S.Sel.Clear(); foreach ($i in $script:S.Catalog.Items | Where-Object Required) { [void]$script:S.Sel.Add($i.Id) }
    $add = @($b.Items | Where-Object { (Get-IpPlan $script:S.Catalog.ById[$_]).Ok }); foreach ($i in $add) { [void]$script:S.Sel.Add($i) }
    $script:S.Bundle = $Id
    $miss = @($b.Items).Count - $add.Count
    Show-IpToast ("Balíček »$($b.Name)«: $($add.Count) $(Get-IpPlural $add.Count 'program' 'programy' 'programů') + povinný základ" + $(if ($miss) { " · $miss teď nedostupné (viz kontrolky)" } else { '' }) + '. Upravit ho můžete vpravo.')
    Update-IpMain
}
function Clear-IpSelection {
    $script:S.Sel.Clear(); foreach ($i in $script:S.Catalog.Items | Where-Object Required) { [void]$script:S.Sel.Add($i.Id) }
    $script:S.Bundle = $null
    Show-IpToast 'Zůstal jen povinný základ. Programy přidáte vpravo.'
    Update-IpMain
}

#endregion

#region Hlavní okno – sloupec 2 (vybrané programy)

function Get-IpSourceChip { param($Item, $Plan)
    if (-not $Plan.Ok) { return New-IpChip 'nedostupné' $script:Col.Err $script:Col.ErrSoft $Plan.Reason }
    $ctx = Get-IpCtx
    if ($Plan.Source -eq 'nas') {
        if ($Item.Winget -and $ctx.NetOk -and $script:S.Winget) { return New-IpChip 'NAS + internet' $script:Col.Ok $script:Col.OkSoft 'Nejdřív z NAS, při chybě z internetu' }
        return New-IpChip 'jen NAS' $script:Col.Warn $script:Col.WarnSoft $(if ($Item.Winget) { 'Internet nefunguje – záloha přes winget teď není k dispozici' } else { 'Program je jen na NAS' })
    }
    $onNas = $Item.Sources -contains 'nas' -and @(Get-IpCandidates -Index $script:S.Index -ItemId $Item.Id).Count
    if ($onNas -and $Item.Sources[0] -eq 'winget') {
        # Internet je pro tento program první volba (na NAS je jen online instalátor nebo instalátor s oknem).
        return New-IpChip 'internet' $script:Col.Muted $script:Col.Surface2 'Z internetu tiše přes winget; instalátor na NAS je jen online nebo s oknem'
    }
    if ($onNas -and -not $Item.NasNeedsInternet) {
        return New-IpChip 'internet (záloha)' $script:Col.Accent $script:Col.AccentSoft 'NAS je nedostupný, použije se internet'
    }
    return New-IpChip 'jen internet' $script:Col.Muted $script:Col.Surface2 'Stáhne se z internetu přes winget'
}

function Get-IpTags { param($Item, $Plan)
    $sp = New-IpPanel 'Horizontal'
    [void]$sp.Children.Add((New-IpText $Item.Name 13.5 'SemiBold' $(if ($Plan.Ok) { '' } else { $script:Col.Muted }) -Margin '0,0,8,0'))
    if ($Item.Required) { [void]$sp.Children.Add((New-IpChip 'POVINNÉ' $script:Col.Accent $script:Col.AccentSoft)) }
    if ($Item.Exception) { [void]$sp.Children.Add((New-IpChip 'NEDOPORUČENO' $script:Col.Err $script:Col.ErrSoft 'Skript tento soubor vyloučil. Povoleno ručně jen pro tuto relaci.')) }
    $inter = $Item.Interactive -or $Item.Exception -or ($Plan.Ok -and $Plan.Source -eq 'nas' -and ($Item.NasInteractive -or ($Plan.Candidate -and $Plan.Candidate.Kind -eq 'exe' -and -not (Get-IpValue $Item.Args 'exe' ''))))
    if ($inter) { [void]$sp.Children.Add((New-IpChip 'S OKNEM' $script:Col.Warn $script:Col.WarnSoft 'Instalátor neumí ověřenou tichou instalaci – otevře vlastní okno')) }
    return $sp
}

function New-IpSelRow { param($Item)
    $plan = Get-IpPlan $Item
    $g = New-Object Windows.Controls.Grid; $g.Margin = '14,8,8,8'
    foreach ($w in @('2*', '140', '190', '180', '170', '36')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
    $nm = New-IpPanel; $nm.VerticalAlignment = 'Center'
    [void]$nm.Children.Add((Get-IpTags $Item $plan))
    if (-not $plan.Ok) { $sub = New-IpText "Nenainstaluje se: $($plan.Reason)" 12 'Normal' $script:Col.Err -Wrap }
    elseif ($Item.Exception) { $sub = New-IpText $Item.Why 12 'Normal' $script:Col.Warn -Wrap }
    elseif ($plan.Source -eq 'nas') { $sub = New-IpText $plan.Candidate.Rel 11.5 'Normal' $script:Col.Muted -Font 'Consolas'; $sub.TextTrimming = 'CharacterEllipsis'; $sub.ToolTip = $plan.Candidate.Path }
    else { $sub = New-IpText 'stáhne se z internetu (winget)' 12 'Normal' $script:Col.Muted }
    [void]$nm.Children.Add($sub)
    if ($plan.Ok -and $plan.Note) { [void]$nm.Children.Add((New-IpText $plan.Note 12 'Normal' $script:Col.Warn -Wrap)) }
    [void]$g.Children.Add($nm)

    $src = Get-IpSourceChip $Item $plan; [Windows.Controls.Grid]::SetColumn($src, 1); [void]$g.Children.Add($src)

    # verze: výběr jen když je na NAS víc verzí
    $cands = @(Get-IpCandidates -Index $script:S.Index -ItemId $Item.Id)
    if ($plan.Ok -and $plan.Source -eq 'nas' -and $cands.Count -gt 1 -and -not $Item.Exception) {
        $cb = New-Object Windows.Controls.ComboBox; $cb.Tag = $Item.Id; $cb.IsEnabled = -not (Test-IpBusy); $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,12,0'
        $cb.ToolTip = "Na NAS jsou $($cands.Count) verze tohoto programu. Doporučená je nejnovější."
        foreach ($c in $cands) {
            $ci = New-Object Windows.Controls.ComboBoxItem
            $inst = $script:S.Installed[$Item.Id]
            $ci.Content = $c.Version + $(if ($c.Recommended) { ' · doporučeno' } else { '' }) + $(if ($inst -and $inst.Installed -and $inst.Version -and (Compare-IpVersion $inst.Version $c.Version) -eq 0) { ' · na PC' } else { '' })
            $ci.Tag = $c.Version; [void]$cb.Items.Add($ci)
            if ($c.Version -eq $plan.Version) { $cb.SelectedItem = $ci }
        }
        $cb.Add_SelectionChanged({ param($s, $e) Invoke-IpSafe { if ($s.SelectedItem) { $script:S.Ver[$s.Tag] = $s.SelectedItem.Tag; Update-IpMiddle } } })
        $vEl = $cb
    }
    elseif (-not $plan.Ok) { $vEl = New-IpText '—' 13 'Normal' $script:Col.Muted }
    elseif ($plan.Source -eq 'winget') { $vEl = New-IpText 'nejnovější z winget' 12.5 'Normal' $script:Col.Muted }
    elseif ($Item.NasNeedsInternet) { $vEl = New-IpText 'online instalátor' 12.5 'Normal' $script:Col.Muted }
    else { $vEl = New-IpText $plan.Version 12.5 'Normal' '' -Font 'Consolas' }
    $vEl.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($vEl, 2); [void]$g.Children.Add($vEl)

    # pro koho
    if (-not $plan.Ok) { $sEl = New-IpText '—' 13 'Normal' $script:Col.Muted }
    elseif ($Item.Scope -eq 'machine') { $sEl = New-IpText 'jen pro všechny' 12.5 'Normal' $script:Col.Muted; $sEl.ToolTip = $Item.Why }
    else {
        $sEl = New-IpPanel 'Horizontal'; $sEl.ToolTip = $Item.Why
        foreach ($k in 'all', 'user') {
            $rb = New-Object Windows.Controls.RadioButton
            $rb.Style = $script:S.Win.FindResource('Seg'); $rb.GroupName = "scope_$($Item.Id)"; $rb.Tag = "$($Item.Id)|$k"
            $cp = New-IpPanel 'Horizontal'; [void]$cp.Children.Add((New-IpText $(if ($k -eq 'all') { 'Všichni' } else { 'Uživatel' }) 12.5))
            if ($k -eq $Item.Recommended) { $el = New-Object Windows.Shapes.Ellipse; $el.Width = 6; $el.Height = 6; $el.Fill = Get-IpBrush $script:Col.Ok; $el.Margin = '6,0,0,0'; $el.VerticalAlignment = 'Center'; [void]$cp.Children.Add($el) }
            $rb.Content = $cp
            $rb.IsChecked = $plan.Scope -eq $k
            $rb.IsEnabled = -not (Test-IpBusy) -and ($k -eq 'all' -or $script:S.User)
            if ($k -eq 'user') { $rb.BorderThickness = '1' }
            $rb.Add_Checked({ param($s, $e) Invoke-IpSafe { $p = $s.Tag -split '\|'; if ((Get-IpScopeOf $script:S.Catalog.ById[$p[0]]) -ne $p[1] -or -not $script:S.Scope.ContainsKey($p[0])) { $script:S.Scope[$p[0]] = $p[1]; Update-IpMiddle } } })
            [void]$sEl.Children.Add($rb)
        }
    }
    $sEl.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($sEl, 3); [void]$g.Children.Add($sEl)

    $stt = Get-IpStatusText $Item
    $sc = @{ miss = @($script:Col.Muted, 'Transparent'); ok = @($script:Col.Ok, $script:Col.OkSoft); upd = @($script:Col.Accent, $script:Col.AccentSoft) }[$stt[0]]
    $stEl = New-IpChip $stt[1] $sc[0] $sc[1]; [Windows.Controls.Grid]::SetColumn($stEl, 4); [void]$g.Children.Add($stEl)

    if ($Item.Required) { $rm = New-IpText ([string][char]0xE72E) 14 'Normal' $script:Col.Muted -Font 'Segoe MDL2 Assets'; $rm.ToolTip = 'Povinný program nelze odebrat' }
    else {
        $rm = New-IpButton ([string][char]0xE711) 'Link' $Item.Id; $rm.FontFamily = 'Segoe MDL2 Assets'; $rm.Foreground = Get-IpBrush $script:Col.Muted
        $rm.ToolTip = "Odebrat $($Item.Name) z výběru"; $rm.IsEnabled = -not (Test-IpBusy)
        $rm.Add_Click({ param($s, $e) Invoke-IpSafe { [void]$script:S.Sel.Remove($s.Tag); Show-IpToast "»$((Get-IpAllItems | Where-Object Id -eq $s.Tag).Name)« odebráno z výběru. Vrátit ho můžete vpravo."; Update-IpMain } })
    }
    $rm.VerticalAlignment = 'Center'; $rm.HorizontalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($rm, 5); [void]$g.Children.Add($rm)
    return $g
}

function Get-IpNotes {
    $n = New-Object System.Collections.Generic.List[object]
    $sel = @(Get-IpSelected); $plans = @{}; foreach ($i in $sel) { $plans[$i.Id] = Get-IpPlan $i }
    foreach ($i in $sel | Where-Object { $_.Required -and -not $plans[$_.Id].Ok }) { $n.Add(@('err', "$($i.Name) se nenainstaluje: $($plans[$i.Id].Reason). Klikněte nahoře na kontrolku – ukáže návod.")) }
    foreach ($i in $sel | Where-Object { -not $_.Required -and -not $plans[$_.Id].Ok }) { $n.Add(@('err', "$($i.Name) se nenainstaluje: $($plans[$i.Id].Reason).")) }
    foreach ($i in $sel | Where-Object Exception) { $n.Add(@($(if ($i.Risk -eq 'err') { 'err' } else { 'warn' }), "$($i.Name) – nedoporučeno: $($i.Why)")) }
    if ($script:S.UseBroker) {
        $manual = @($sel | Where-Object { $plans[$_.Id].Ok -and ($_.Exception -or (($_.Interactive -or $_.Type -eq 'office') -and $plans[$_.Id].Source -eq 'nas')) })
        if ($manual.Count) { $n.Add(@('err', ("Bez práv správce se nenainstaluje (potřebuje okno průvodce nebo je to ruční výjimka): " + (($manual | ForEach-Object Name) -join ', ') + '. Ty nainstaluje IT.'))) }
    }
    if ((Get-IpState 'nas') -eq 'warn') { $n.Add(@('warn', 'NAS odpovídá pomalu – instalace z NAS potrvají déle. Návod: kontrolka NAS.')) }
    # Pozor: v @(a, b + c) má čárka přednost před +, proto text vždy v závorce.
    if ((Get-IpState 'inet') -eq 'warn') { $n.Add(@('warn', ((Get-IpHealthCheck 'inet').Title + '. Návod: kontrolka Internet.'))) }
    if ((Get-IpState 'sophos') -eq 'warn') { $n.Add(@('warn', 'Instalátor Sophos je starý. Nainstaluje se, ale první aktualizace potrvá déle.')) }
    if ((Get-IpState 'disk') -ne 'ok') { $n.Add(@((Get-IpState 'disk'), (Get-IpHealthCheck 'disk').Detail)) }
    foreach ($i in $sel | Where-Object { $plans[$_.Id].Ok -and $plans[$_.Id].Note }) { $n.Add(@('info', "$($i.Name): $($plans[$i.Id].Note)")) }
    foreach ($i in $sel | Where-Object { $plans[$_.Id].Ok -and $plans[$_.Id].Scope -eq 'user' -and $_.Recommended -eq 'all' }) { $n.Add(@('warn', "$($i.Name) jen pro uživatele: $($i.Why)")) }
    foreach ($i in $sel | Where-Object { $p = $plans[$_.Id]; $p.Ok -and $p.Source -eq 'nas' -and $p.Candidate -and -not $p.Candidate.Recommended -and -not $_.Exception }) {
        $rec = @(Get-IpCandidates -Index $script:S.Index -ItemId $i.Id | Where-Object Recommended)[0]
        $n.Add(@('info', "$($i.Name): vybrána starší verze $($plans[$i.Id].Version) (doporučená je $($rec.Version))."))
    }
    foreach ($i in $sel | Where-Object { $_.Pin -and $plans[$_.Id].Ok }) { $n.Add(@('info', "$($i.Name): aplikace bývají vázané na konkrétní verzi runtime. Ověřte, kterou vaše aplikace vyžaduje.")) }
    if (@($sel | Where-Object { $plans[$_.Id].Ok -and $plans[$_.Id].Scope -eq 'user' }).Count -and $script:S.User) { $n.Add(@('info', "Instalace »Uživatel« poběží v relaci $($script:S.User.Short), ne pod účtem správce. Uživatel musí zůstat přihlášený.")) }
    $inter = @($sel | Where-Object { $plans[$_.Id].Ok -and ($_.Interactive -or $_.Exception -or ($plans[$_.Id].Source -eq 'nas' -and $_.NasInteractive)) })
    if ($inter.Count) { $n.Add(@('warn', ((($inter | ForEach-Object Name) -join ', ') + ' ' + $(if ($inter.Count -gt 1) { 'otevřou' } else { 'otevře' }) + ' vlastní okno instalátoru. Zůstaňte u počítače.'))) }
    $close = @($sel | Where-Object { $plans[$_.Id].Ok -and @($_.CloseProcesses | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue }).Count })
    if ($close.Count) { $n.Add(@('warn', ('Před instalací se zavřou běžící programy: ' + (($close | ForEach-Object Name) -join ', ') + '. Uložte si práci.'))) }
    $skip = @($sel | Where-Object { $plans[$_.Id].Ok -and (Get-IpStatusText $_)[0] -eq 'ok' -and -not $_.Exception })
    if ($skip.Count) { $n.Add(@('na', ('Už nainstalováno, přeskočí se: ' + (($skip | ForEach-Object Name) -join ', ') + '.'))) }
    # Čárka: jediné upozornění (pole dvou řetězců) by se jinak rozbalilo na dva řetězce.
    return , $n.ToArray()
}

function Update-IpMiddle {
    if ($script:S.Run) { Update-IpRun; return }
    $script:C.SelScroll.Visibility = 'Visible'; $script:C.RunPanel.Visibility = 'Collapsed'
    $script:C.ModePanel.IsEnabled = $true; $script:C.MidTitle.Text = 'Vybrané programy'
    $off = $script:C.SelScroll.VerticalOffset
    $p = $script:C.SelList; $p.Children.Clear()
    $sel = @(Get-IpSelected); $ok = @($sel | Where-Object { (Get-IpPlan $_).Ok })
    $script:C.MidCount.Text = "$($ok.Count) $(Get-IpPlural $ok.Count 'program' 'programy' 'programů') k instalaci"

    $notes = Get-IpNotes
    if ($notes.Count) {
        $np = New-IpPanel
        foreach ($nt in $notes) {
            $g = New-Object Windows.Controls.Grid; $g.Margin = '0,4,0,4'
            foreach ($w in @('28', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
            [void]$g.Children.Add((New-IpStateIcon $nt[0] 20)); $t = New-IpText $nt[1] 13 'Normal' '' -Wrap; [Windows.Controls.Grid]::SetColumn($t, 1); [void]$g.Children.Add($t)
            [void]$np.Children.Add($g)
        }
        $ex = New-Object Windows.Controls.Expander; $ex.IsExpanded = $true; $ex.Content = $np
        $ex.Header = New-IpText "Před instalací · $($notes.Count) $(Get-IpPlural $notes.Count 'upozornění' 'upozornění' 'upozornění')" 13.5 'SemiBold'
        [void]$p.Children.Add((New-IpBorder -Child $ex -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10 -Padding '12,8' -Margin '0,8,0,4'))
    }
    $hdr = New-Object Windows.Controls.Grid; $hdr.Margin = '14,10,8,2'
    $i = 0; foreach ($w in @('2*', '140', '190', '180', '170', '36')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $hdr.ColumnDefinitions.Add($cd) }
    foreach ($h in 'PROGRAM', 'ZDROJ', 'VERZE', 'PRO KOHO', 'NA TOMTO PC') { $t = New-IpText $h 11 'SemiBold' $script:Col.Muted; [Windows.Controls.Grid]::SetColumn($t, $i); $i++; [void]$hdr.Children.Add($t) }
    [void]$p.Children.Add($hdr)

    $bIds = if ($null -ne $script:S.Bundle) { @(($script:S.Catalog.Bundles | Where-Object Id -eq $script:S.Bundle).Items) } else { @() }
    $chosen = @($sel | Where-Object { -not $_.Required })
    $groups = @(, @('Povinný základ', 'vždy se instaluje', @(Get-IpAllItems | Where-Object Required)))
    if ($null -ne $script:S.Bundle) {
        $fb = @($chosen | Where-Object { $bIds -contains $_.Id }); $bn = ($script:S.Catalog.Bundles | Where-Object Id -eq $script:S.Bundle).Name
        $groups += , @("Z balíčku »$bn«", $(if ($fb.Count) { "$($fb.Count) $(Get-IpPlural $fb.Count 'program' 'programy' 'programů')" } else { 'všechny programy balíčku jste odebrali' }), $fb)
    }
    $man = @($chosen | Where-Object { $bIds -notcontains $_.Id })
    if ($man.Count) { $groups += , @('Přidáno ručně', "$($man.Count) $(Get-IpPlural $man.Count 'program' 'programy' 'programů')", $man) }
    foreach ($gr in $groups) {
        $h = New-IpPanel 'Horizontal' '4,16,0,6'; [void]$h.Children.Add((New-IpText $gr[0] 14 'Bold')); [void]$h.Children.Add((New-IpText "  $($gr[1])" 12.5 'Normal' $script:Col.Muted))
        [void]$p.Children.Add($h)
        if (@($gr[2]).Count) {
            $box = New-IpPanel
            $first = $true
            foreach ($it in $gr[2]) {
                if (-not $first) { [void]$box.Children.Add((New-IpBorder -BorderColor $script:Col.Line2 -Thickness '0,1,0,0')) }
                $first = $false; [void]$box.Children.Add((New-IpSelRow $it))
            }
            [void]$p.Children.Add((New-IpBorder -Child $box -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10))
        }
    }
    if (-not $chosen.Count) { [void]$p.Children.Add((New-IpText 'Zatím jen povinný základ. Vyberte balíček vlevo nebo přidejte programy vpravo.' 13 'Normal' $script:Col.Muted -Margin '4,20,0,0')) }
    $script:C.SelScroll.ScrollToVerticalOffset($off)

    $all = @($ok | Where-Object { (Get-IpPlan $_).Scope -eq 'all' }).Count; $usr = $ok.Count - $all
    $inet = @($ok | Where-Object { (Get-IpPlan $_).Source -eq 'winget' }).Count
    $min = [Math]::Max(1, [Math]::Round((@($ok | ForEach-Object { if ($_.Id -eq 'm365') { 12 } elseif ($_.Interactive) { 4 } else { 1.2 } }) | Measure-Object -Sum).Sum))
    $uname = if ($script:S.User) { $script:S.User.Short } else { 'uživatele' }
    $script:C.SumText.Text = "$all pro všechny uživatele · $usr jen pro $uname · $inet z internetu · odhad $min min"
    $script:C.BtnInstall.Content = "Instalovat vybrané ($($ok.Count))"
    $script:C.BtnInstall.IsEnabled = $ok.Count -gt 0 -and -not $script:S.Checking
    $script:C.BtnInstall.Visibility = 'Visible'; $script:C.BtnCancel.Visibility = 'Collapsed'; $script:C.BtnNew.Visibility = 'Collapsed'; $script:C.BtnLog.Visibility = 'Collapsed'
    $script:C.BtnClear.IsEnabled = @($chosen).Count -gt 0 -or $null -ne $script:S.Bundle
    $script:C.RbUser.Content = "Jen $uname"; $script:C.RbUser.IsEnabled = [bool]$script:S.User
}

#endregion

#region Hlavní okno – sloupec 3 (přidat nebo odebrat)

function Update-IpCatalogCombo {
    $cb = $script:C.CmbCat; $cur = $script:S.Cat
    $script:S.Updating = $true
    $cb.Items.Clear(); [void]$cb.Items.Add('Všechny kategorie')
    foreach ($c in $script:S.Catalog.Categories | Where-Object id -ne 'zaklad') { [void]$cb.Items.Add([string]$c.name) }
    if ($script:S.Allowed.Count) { [void]$cb.Items.Add($script:ExCategory) }
    $cb.SelectedItem = if ($cb.Items.Contains($cur)) { $cur } else { 'Všechny kategorie' }
    $script:S.Updating = $false
}

function Get-IpCatName { param($Item)
    if ($Item.Exception) { return $script:ExCategory }
    return [string](($script:S.Catalog.Categories | Where-Object id -eq $Item.Category).name)
}

function Update-IpCatalog {
    $off = $script:C.CatScroll.VerticalOffset
    $p = $script:C.CatList; $p.Children.Clear()
    $q = $script:S.Query.Trim().ToLowerInvariant(); $busy = Test-IpBusy
    $items = @(Get-IpAllItems | Where-Object { -not $_.Required } | Where-Object {
            ($script:S.Cat -eq 'Všechny kategorie' -or (Get-IpCatName $_) -eq $script:S.Cat) -and
            (-not $q -or $_.Name.ToLowerInvariant().Contains($q)) -and
            (-not $script:S.Miss -or (Get-IpStatusText $_)[0] -ne 'ok') })
    if (-not $items.Count) { [void]$p.Children.Add((New-IpText 'Nic neodpovídá filtru. Zkuste jinou kategorii nebo smažte hledání.' 13 'Normal' $script:Col.Muted -Wrap -Margin '6,16,6,0')) }
    $cats = @($script:S.Catalog.Categories | Where-Object id -ne 'zaklad' | ForEach-Object name) + @($script:ExCategory)
    foreach ($cn in $cats) {
        $arr = @($items | Where-Object { (Get-IpCatName $_) -eq $cn }); if (-not $arr.Count) { continue }
        $avail = @($arr | Where-Object { (Get-IpPlan $_).Ok }); $sel = @($avail | Where-Object { $script:S.Sel.Contains($_.Id) }).Count
        $h = New-Object Windows.Controls.DockPanel; $h.Margin = '4,14,0,4'
        $acts = New-IpPanel 'Horizontal'; [Windows.Controls.DockPanel]::SetDock($acts, 'Right')
        $a1 = New-IpButton 'Vybrat vše' 'Link' "$cn|add"; $a1.IsEnabled = -not $busy -and $sel -lt $avail.Count; $a1.FontSize = 12
        $a2 = New-IpButton 'Odebrat vše' 'Link' "$cn|del"; $a2.IsEnabled = -not $busy -and $sel -gt 0; $a2.FontSize = 12
        foreach ($a in $a1, $a2) { $a.Add_Click({ param($s, $e) Invoke-IpSafe { Set-IpCategorySelection $s.Tag } }); [void]$acts.Children.Add($a) }
        [void]$h.Children.Add($acts)
        $tl = New-IpPanel 'Horizontal'; [void]$tl.Children.Add((New-IpText $cn 13 'SemiBold')); [void]$tl.Children.Add((New-IpText "  $sel z $($avail.Count)" 12 'Normal' $script:Col.Muted)); $tl.VerticalAlignment = 'Center'
        [void]$h.Children.Add($tl)
        [void]$p.Children.Add($h)
        foreach ($it in $arr) {
            $plan = Get-IpPlan $it
            $cb = New-Object Windows.Controls.CheckBox; $cb.Tag = $it.Id; $cb.Margin = '2,0,0,0'; $cb.Padding = '8,0,0,0'
            $cb.IsChecked = $script:S.Sel.Contains($it.Id) -and $plan.Ok; $cb.IsEnabled = $plan.Ok -and -not $busy; $cb.HorizontalContentAlignment = 'Stretch'
            $cp = New-IpPanel; [void]$cp.Children.Add((Get-IpTags $it $plan))
            $line = New-IpPanel 'Horizontal' '0,3,0,0'
            if ($plan.Ok) { [void]$line.Children.Add((Get-IpSourceChip $it $plan)); [void]$line.Children.Add((New-IpText (Get-IpStatusText $it)[1] 12 'Normal' $script:Col.Muted)) }
            else { [void]$line.Children.Add((New-IpText $plan.Reason 12 'Normal' $script:Col.Err -Wrap)) }
            [void]$cp.Children.Add($line); $cb.Content = $cp
            $cb.Add_Click({ param($s, $e) Invoke-IpSafe { if ($s.IsChecked) { [void]$script:S.Sel.Add($s.Tag) } else { [void]$script:S.Sel.Remove($s.Tag) }; Update-IpMain } })
            $bd = New-IpBorder -Child $cb -BorderColor $script:Col.Line2 -Thickness '0,1,0,0' -Padding '6,8' -Bg $(if ($cb.IsChecked) { '#EAF5F6' } else { 'Transparent' })
            [void]$p.Children.Add($bd)
        }
    }
    $script:C.CatScroll.ScrollToVerticalOffset($off)
}

function Set-IpCategorySelection { param([string] $Tag)
    $cn, $act = $Tag -split '\|'
    foreach ($it in @(Get-IpAllItems | Where-Object { -not $_.Required -and (Get-IpCatName $_) -eq $cn -and (Get-IpPlan $_).Ok })) {
        if ($act -eq 'add') { [void]$script:S.Sel.Add($it.Id) } else { [void]$script:S.Sel.Remove($it.Id) }
    }
    Update-IpMain
}

function Update-IpLeftRightEnabled {
    $busy = Test-IpBusy
    $script:C.BundleList.IsEnabled = -not $busy; $script:C.CatList.IsEnabled = -not $busy
    $script:C.TxtSearch.IsEnabled = -not $busy; $script:C.CmbCat.IsEnabled = -not $busy; $script:C.ChkMissing.IsEnabled = -not $busy
    $script:C.BusyNote.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
}

function Update-IpMain { Update-IpBundles; Update-IpMiddle; Update-IpCatalog; Update-IpLeftRightEnabled; Update-IpHeader }
function Update-IpAll { Update-IpHeader; Update-IpStart; Update-IpCatalogCombo; Update-IpBundles; Update-IpMiddle; Update-IpCatalog; Update-IpLeftRightEnabled }

#endregion

#region Instalace

function Start-IpInstall { param([object[]] $Only)
    if (Test-IpBusy) { return }
    $ctx = Get-IpCtx
    $order = if ($Only) { $Only } else { @(Get-IpAllItems | Where-Object Required) + @(Get-IpAllItems | Where-Object { -not $_.Required -and $script:S.Sel.Contains($_.Id) }) }
    $plan = New-Object System.Collections.Generic.List[object]
    if (-not $Only -or -not $script:S.Run) {
        $script:S.Run = @{ Entries = New-Object System.Collections.ArrayList; Dialogs = New-Object System.Collections.ArrayList; Done = $false; Reboot = $false; State = [hashtable]::Synchronized(@{ Cancel = $false }) }
        $script:C.LogBox.Clear()
    }
    else { $script:S.Run.Done = $false; $script:S.Run.State['Cancel'] = $false; $script:S.Run.Dialogs.Clear() }
    foreach ($it in $order) {
        $pe = Get-IpPlan $it
        $entry = $script:S.Run.Entries | Where-Object Id -eq $it.Id | Select-Object -First 1
        if (-not $entry) { $entry = [pscustomobject]@{ Id = $it.Id; Name = $it.Name; Status = 'wait'; Msg = 'čeká'; Result = $null }; [void]$script:S.Run.Entries.Add($entry) }
        if ($pe.Ok) { $entry.Status = 'wait'; $entry.Msg = 'čeká'; $entry.Result = $null; $plan.Add($pe) }
        else {
            $entry.Status = 'err'; $entry.Msg = "nedostupné: $($pe.Reason)"
            $key = if ($it.Id -eq 'sophos') { 'sophos' } elseif ($it.Id -eq 'font-code128') { 'font' } elseif ((Get-IpState 'nas') -eq 'err') { 'nas' } else { 'inet' }
            $hc = Get-IpHealthCheck $key
            $entry.Result = [pscustomobject]@{ Id = $it.Id; Name = $it.Name; Result = 'Failed'; Message = $pe.Reason
                Problem = [pscustomobject]@{ Title = "$($it.Name) se nenainstaluje"; What = "$($pe.Reason)."; Tried = 'Aplikace ověřila NAS i internet těsně před instalací.'; Check = @(@($hc.Steps | ForEach-Object { $_[0] }) + 'Pak klikněte na Zkusit znovu.'); Key = $key } }
        }
    }
    Write-IpLog -Settings $script:S.Settings -Message ("Výběr: " + (($order | ForEach-Object Name) -join ', '))
    Update-IpMain
    if (-not $plan.Count) { $script:S.Run.Done = $true; Update-IpMain; return }
    if ($script:S.UseBroker) {
        Start-IpJob -Kind 'install' -Script $script:BrokerJob -Params @{ Plan = $plan.ToArray(); Settings = $script:S.Settings; Queue = $script:S.Queue; State = $script:S.Run.State }
        return
    }
    Start-IpJob -Kind 'install' -Script $script:InstallJob -Params @{ Plan = $plan.ToArray(); Ctx = $ctx; Settings = $script:S.Settings; Queue = $script:S.Queue; State = $script:S.Run.State }
}

function Update-IpRun {
    $r = $script:S.Run
    $script:C.SelScroll.Visibility = 'Collapsed'; $script:C.RunPanel.Visibility = 'Visible'; $script:C.ModePanel.IsEnabled = $false
    $total = $r.Entries.Count; $done = @($r.Entries | Where-Object { $_.Status -in @('ok', 'skip', 'err', 'cancel') }).Count
    $script:C.MidTitle.Text = if ($r.Done) { 'Instalace dokončena' } else { 'Probíhá instalace' }
    $script:C.MidCount.Text = "$done z $total"
    $script:C.Prog.Maximum = [Math]::Max(1, $total); $script:C.Prog.Value = $done
    $cur = $r.Entries | Where-Object { $_.Status -in @('running', 'attn') } | Select-Object -First 1
    $script:C.ProgText.Text = if ($r.Done) { 'Hotovo.' } elseif ($cur) { "($($done + 1)/$total) $($cur.Name): $($cur.Msg)" } else { 'Připravuji…' }

    $okN = @($r.Entries | Where-Object Status -eq 'ok').Count; $skN = @($r.Entries | Where-Object Status -eq 'skip').Count; $erN = @($r.Entries | Where-Object Status -eq 'err').Count
    if ($r.Done) {
        $sp = $script:C.SummaryPanel; $sp.Children.Clear()
        $script:C.SummaryBox.Visibility = 'Visible'; $script:C.SummaryBox.Background = Get-IpBrush $(if ($erN) { $script:Col.WarnSoft } else { $script:Col.OkSoft })
        [void]$sp.Children.Add((New-IpText $(if ($erN) { "Hotovo, $erN $(Get-IpPlural $erN 'položka vyžaduje' 'položky vyžadují' 'položek vyžaduje') pozornost" } else { 'Hotovo, vše nainstalováno' }) 16 'Bold'))
        [void]$sp.Children.Add((New-IpText "$okN nainstalováno · $skN přeskočeno · $erN chyb" 13 'Normal' '' -Margin '0,4,0,0'))
        if ($r.Reboot) { [void]$sp.Children.Add((New-IpText 'Některé programy vyžadují restart. Restartujte počítač, až dokončíte práci.' 13 'SemiBold' $script:Col.Warn -Wrap -Margin '0,4,0,0')) }
        [void]$sp.Children.Add((New-IpText "Log: $(Get-IpLogFile)" 12 'Normal' $script:Col.Muted -Wrap -Margin '0,4,0,0'))
    }
    else { $script:C.SummaryBox.Visibility = 'Collapsed' }

    $pp = $script:C.ProbList; $pp.Children.Clear()
    foreach ($d in $r.Dialogs) {
        $card = New-IpPanel; [void]$card.Children.Add((New-IpText "Instalátor zobrazil okno »$($d.Title)«" 14 'SemiBold'))
        [void]$card.Children.Add((New-IpText 'Tichá instalace by okno zobrazit neměla. Pokud v něm instalátor čeká na odpověď, dokončete ho – jinak se po časovém limitu ukončí.' 13 'Normal' '' -Wrap -Margin '0,4,0,0'))
        $b = New-IpButton 'Přepnout do okna' 'Btn' $d.Pid '0,8,0,0' '10,4'; $b.HorizontalAlignment = 'Left'
        $b.Add_Click({ param($s, $e) Invoke-IpSafe { $sh = New-Object -ComObject WScript.Shell; if (-not $sh.AppActivate([int]$s.Tag)) { Show-IpToast 'Okno už není otevřené.' } } })
        [void]$card.Children.Add($b)
        [void]$pp.Children.Add((New-IpBorder -Child $card -Bg $script:Col.WarnSoft -BorderColor $script:Col.Warn -Thickness '1' -Radius 10 -Padding '14,12' -Margin '0,0,0,10'))
    }
    foreach ($e in @($r.Entries | Where-Object { $_.Status -eq 'err' -and $_.Result -and $_.Result.Problem })) {
        $pr = $e.Result.Problem
        $card = New-IpPanel
        $h = New-IpPanel 'Horizontal'; [void]$h.Children.Add((New-IpStateIcon 'err' 20)); $tt = New-IpText $pr.Title 14 'SemiBold' -Margin '8,0,0,0'; [void]$h.Children.Add($tt); [void]$card.Children.Add($h)
        [void]$card.Children.Add((New-IpText $pr.What 13 'Normal' '' -Wrap -Margin '0,6,0,0'))
        if ($pr.Tried) { [void]$card.Children.Add((New-IpText 'CO APLIKACE ZKUSILA' 11 'SemiBold' $script:Col.Muted -Margin '0,8,0,2')); [void]$card.Children.Add((New-IpText $pr.Tried 13 'Normal' '' -Wrap)) }
        [void]$card.Children.Add((New-IpText 'CO ZKONTROLOVAT' 11 'SemiBold' $script:Col.Muted -Margin '0,8,0,2'))
        $n = 0; foreach ($c in @($pr.Check)) { $n++; [void]$card.Children.Add((New-IpText "$n. $c" 13 'Normal' '' -Wrap)) }
        $acts = New-IpPanel 'Horizontal' '0,10,0,0'
        $b1 = New-IpButton 'Zkusit znovu' 'Primary' $e.Id '0,0,8,0' '12,5'; $b1.IsEnabled = $r.Done
        $b1.Add_Click({ param($s, $ev) Invoke-IpSafe { $it = Get-IpAllItems | Where-Object Id -eq $s.Tag; Start-IpInstall -Only @($it) } })
        $b2 = New-IpButton 'Přeskočit' 'Btn' $e.Id '0,0,8,0' '12,5'; $b2.IsEnabled = $r.Done
        $b2.Add_Click({ param($s, $ev) Invoke-IpSafe { $x = $script:S.Run.Entries | Where-Object Id -eq $s.Tag; $x.Status = 'skip'; $x.Msg = 'přeskočeno uživatelem'; $x.Result = $null; Write-IpLog -Settings $script:S.Settings -Message "$($x.Name) | PŘESKOČENO uživatelem"; Update-IpRun } })
        [void]$acts.Children.Add($b1); [void]$acts.Children.Add($b2)
        if ($pr.PSObject.Properties['Key'] -and $pr.Key) { $b3 = New-IpButton 'Návod' 'Btn' $pr.Key '' '12,5'; $b3.Add_Click({ param($s, $ev) Invoke-IpSafe { Show-IpStatusWindow -Key $s.Tag } }); [void]$acts.Children.Add($b3) }
        [void]$card.Children.Add($acts)
        [void]$pp.Children.Add((New-IpBorder -Child $card -Bg '#FCEFED' -BorderColor '#E8B4AE' -Thickness '1' -Radius 10 -Padding '14,12' -Margin '0,0,0,10'))
    }
    $rl = $script:C.RunList; $rl.Children.Clear()
    foreach ($e in $r.Entries) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '0,6,0,6'
        foreach ($w in @('30', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
        $ic = switch ($e.Status) { 'ok' { 'ok' } 'err' { 'err' } 'running' { 'run' } 'attn' { 'warn' } default { 'na' } }
        [void]$g.Children.Add((New-IpStateIcon $ic 22))
        $sp = New-IpPanel; [Windows.Controls.Grid]::SetColumn($sp, 1)
        [void]$sp.Children.Add((New-IpText $e.Name 13.5 'SemiBold')); [void]$sp.Children.Add((New-IpText $e.Msg 12.5 'Normal' $script:Col.Muted -Wrap))
        [void]$g.Children.Add($sp)
        [void]$rl.Children.Add($g); [void]$rl.Children.Add((New-IpBorder -BorderColor $script:Col.Line2 -Thickness '0,1,0,0'))
    }
    $script:C.BtnInstall.Visibility = 'Collapsed'
    $script:C.BtnCancel.Visibility = if ($r.Done) { 'Collapsed' } else { 'Visible' }
    $script:C.BtnNew.Visibility = if ($r.Done) { 'Visible' } else { 'Collapsed' }
    $script:C.BtnLog.Visibility = 'Visible'
    $script:C.BtnClear.IsEnabled = $false
    $script:C.SumText.Text = if ($r.Done) { 'Výběr můžete upravit a spustit znovu tlačítkem Nová instalace.' } else { 'Instalace běží na pozadí – okno můžete nechat otevřené.' }
}

#endregion

#region Okno Stav a návod

function Show-IpStatusWindow { param([string] $Key)
    if (-not $script:S.Health) { Show-IpToast 'Kontrola ještě probíhá, za chvíli to půjde.'; return }
    $script:S.StatusKey = $Key
    if ($script:S.StatusWin) { Update-IpStatusWindow; $script:S.StatusWin.Activate() | Out-Null; return }
    $w = New-Object Windows.Window
    $w.Title = 'Stav a návod'; $w.Owner = $script:S.Win; $w.WindowStartupLocation = 'CenterOwner'
    $wa = [Windows.SystemParameters]::WorkArea
    $w.Width = [Math]::Min(1240, $wa.Width - 60); $w.Height = $wa.Height - 60
    $w.Background = Get-IpBrush $script:Col.Bg; $w.FontFamily = 'Segoe UI'; $w.FontSize = 13.5
    $w.Add_Closed({ $script:S.StatusWin = $null }); Set-IpOffscreen $w
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $script:S.StatusWin = $w
    Update-IpStatusWindow
    [void]$w.ShowDialog()
}

function Update-IpStatusWindow {
    $w = $script:S.StatusWin; if (-not $w) { return }
    $key = $script:S.StatusKey
    $c = Get-IpHealthCheck $key; if (-not $c) { $c = $script:S.Health[0]; $key = $c.Key }
    $grid = New-Object Windows.Controls.Grid
    foreach ($wd in @('300', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; $grid.ColumnDefinitions.Add($cd) }

    $left = New-IpPanel -Margin '14,16,14,16'
    [void]$left.Children.Add((New-IpText 'CO SE KONTROLUJE' 11 'SemiBold' $script:Col.Muted -Margin '4,0,0,8'))
    foreach ($h in $script:S.Health) {
        $sp = New-IpPanel 'Horizontal'
        $led = switch ($h.State) { 'ok' { $script:Col.LedOk } 'warn' { $script:Col.LedWarn } default { $script:Col.LedErr } }
        $e = New-Object Windows.Shapes.Ellipse; $e.Width = 12; $e.Height = 12; $e.Fill = Get-IpBrush $led; $e.Margin = '0,0,10,0'; $e.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($e)
        $tx = New-IpPanel; [void]$tx.Children.Add((New-IpText $h.Long 13.5 'SemiBold')); [void]$tx.Children.Add((New-IpText $h.Word 12 'Normal' $script:Col.Muted)); [void]$sp.Children.Add($tx)
        $b = New-IpButton '' 'Btn' $h.Key '0,0,0,6' '12,9'; $b.Content = $sp; $b.HorizontalContentAlignment = 'Left'; $b.FontWeight = 'Normal'
        if ($h.Key -eq $key) { $b.BorderBrush = Get-IpBrush $script:Col.Accent; $b.BorderThickness = '2' }
        $b.Add_Click({ param($s, $ev) Invoke-IpSafe { $script:S.StatusKey = $s.Tag; Update-IpStatusWindow } })
        [void]$left.Children.Add($b)
    }
    $lb = New-IpBorder -Child $left -Bg $script:Col.Surface2 -BorderColor $script:Col.Line -Thickness '0,0,1,0'
    [void]$grid.Children.Add($lb)

    $d = New-IpPanel -Margin '34,26,34,40'; $d.MaxWidth = 900; $d.HorizontalAlignment = 'Left'
    $top = New-IpPanel 'Horizontal'
    $led = switch ($c.State) { 'ok' { $script:Col.LedOk } 'warn' { $script:Col.LedWarn } default { $script:Col.LedErr } }
    $e = New-Object Windows.Shapes.Ellipse; $e.Width = 18; $e.Height = 18; $e.Fill = Get-IpBrush $led; $e.Margin = '0,6,14,0'; $e.VerticalAlignment = 'Top'; [void]$top.Children.Add($e)
    $tt = New-IpPanel; [void]$tt.Children.Add((New-IpText $c.Title 24 'Bold' -Wrap))
    $chipTxt = @{ ok = 'ZELENÁ · V POŘÁDKU'; warn = 'ORANŽOVÁ · PROBLÉM'; err = 'ČERVENÁ · NEFUNGUJE' }[$c.State]
    $chipCol = @{ ok = @($script:Col.Ok, $script:Col.OkSoft); warn = @($script:Col.Warn, $script:Col.WarnSoft); err = @($script:Col.Err, $script:Col.ErrSoft) }[$c.State]
    [void]$tt.Children.Add((New-IpChip $chipTxt $chipCol[0] $chipCol[1])); $tt.Children[1].Margin = '0,6,0,0'
    [void]$tt.Children.Add((New-IpText $c.Detail 15 'Normal' $script:Col.Muted -Wrap -Margin '0,10,0,0'))
    if ($script:S.CheckedAt) { [void]$tt.Children.Add((New-IpText "Zkontrolováno v $($script:S.CheckedAt.ToString('H:mm:ss'))." 12.5 'Normal' $script:Col.Muted -Margin '0,6,0,0')) }
    $tt.MaxWidth = 820; [void]$top.Children.Add($tt); [void]$d.Children.Add($top)

    [void]$d.Children.Add((New-IpText 'POSTUP KROK ZA KROKEM' 11.5 'SemiBold' $script:Col.Muted -Margin '0,26,0,10'))
    if (-not @($c.Steps).Count) { [void]$d.Children.Add((New-IpText 'Vše funguje, není potřeba nic dělat.' 14)) }
    $n = 0
    foreach ($st in $c.Steps) {
        $n++; $id = "$($c.Key)|$($c.State)|$n"; $dn = $script:S.Done.ContainsKey($id) -and $script:S.Done[$id]
        $g = New-Object Windows.Controls.Grid
        foreach ($wd in @('40', '*', 'Auto')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
        $num = New-IpText $(if ($dn) { '✓' } else { "$n" }) 13 'Bold' $(if ($dn) { $script:Col.Ok } else { $script:Col.Accent }); $num.HorizontalAlignment = 'Center'; $num.VerticalAlignment = 'Center'
        $nb = New-IpBorder -Child $num -Bg $(if ($dn) { $script:Col.OkSoft } else { $script:Col.AccentSoft }) -Radius 14; $nb.Width = 28; $nb.Height = 28; $nb.VerticalAlignment = 'Top'
        [void]$g.Children.Add($nb)
        $tx = New-IpPanel; [Windows.Controls.Grid]::SetColumn($tx, 1); [void]$tx.Children.Add((New-IpText $st[0] 14.5 'SemiBold' -Wrap)); [void]$tx.Children.Add((New-IpText $st[1] 13.5 'Normal' $script:Col.Muted -Wrap -Margin '0,3,0,0'))
        [void]$g.Children.Add($tx)
        $chk = New-Object Windows.Controls.CheckBox; $chk.Content = 'hotovo'; $chk.IsChecked = $dn; $chk.Tag = $id; $chk.VerticalAlignment = 'Top'; $chk.Margin = '12,4,0,0'
        $chk.Add_Click({ param($s, $ev) Invoke-IpSafe { $script:S.Done[$s.Tag] = [bool]$s.IsChecked; Update-IpStatusWindow } })
        [Windows.Controls.Grid]::SetColumn($chk, 2); [void]$g.Children.Add($chk)
        $bd = New-IpBorder -Child $g -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10 -Padding '14,12' -Margin '0,0,0,10'
        if ($dn) { $bd.Opacity = 0.65 }
        [void]$d.Children.Add($bd)
    }
    $acts = New-IpPanel 'Horizontal' '0,12,0,0'
    $b1 = New-IpButton 'Zkontrolovat znovu' 'Primary' $null '0,0,10,0'; $b1.IsEnabled = -not $script:S.Checking -and -not (Test-IpBusy)
    $b1.Add_Click({ Invoke-IpSafe { Start-IpHealthCheck -Rescan $true; Show-IpToast 'Kontroluji znovu…'; Update-IpStatusWindow } })
    $b2 = New-IpButton 'Otevřít úvodní kontrolu' 'Btn' $null
    $b2.Add_Click({ Invoke-IpSafe { $script:S.StatusWin.Close(); Set-IpPage 'start' } })
    [void]$acts.Children.Add($b1); [void]$acts.Children.Add($b2); [void]$d.Children.Add($acts)
    if ($script:S.Checking) { [void]$d.Children.Add((New-IpText 'Probíhá kontrola…' 13 'Normal' $script:Col.Muted -Margin '0,8,0,0')) }
    [void]$d.Children.Add((New-IpBorder -Child (New-IpText "Jak to aplikace zjišťuje: $($c.How)" 13 'Normal' $script:Col.Muted -Wrap) -Bg $script:Col.Surface -BorderColor $script:Col.Line2 -Thickness '1' -Radius 8 -Padding '12,10' -Margin '0,22,0,0'))
    $sv = New-Object Windows.Controls.ScrollViewer; $sv.Content = $d; [Windows.Controls.Grid]::SetColumn($sv, 1); [void]$grid.Children.Add($sv)
    $w.Content = $grid
}

#endregion

#region Obsah NAS a výjimky pro relaci

function Show-IpConfirm { param([string] $Title, [string] $Text, [string] $Risk)
    $w = New-Object Windows.Window
    $w.Title = 'Povolit výjimku'; $w.Owner = $script:S.NasWin; $w.WindowStartupLocation = 'CenterOwner'; $w.SizeToContent = 'Height'; $w.Width = 560; $w.ResizeMode = 'NoResize'
    $w.FontFamily = 'Segoe UI'; $w.FontSize = 13.5; $w.Background = Get-IpBrush $script:Col.Surface
    $p = New-IpPanel -Margin '22,20,22,20'
    $h = New-IpPanel 'Horizontal'; [void]$h.Children.Add((New-IpStateIcon $Risk 24)); [void]$h.Children.Add((New-IpText $(if ($Risk -eq 'err') { 'Důrazně nedoporučeno' } else { 'Nedoporučeno' }) 17 'Bold' -Margin '10,0,0,0')); [void]$p.Children.Add($h)
    [void]$p.Children.Add((New-IpText $Title 14 'SemiBold' -Wrap -Margin '0,12,0,0'))
    [void]$p.Children.Add((New-IpText $Text 13.5 'Normal' '' -Wrap -Margin '0,6,0,0'))
    [void]$p.Children.Add((New-IpText 'Povolení platí jen do zavření instalátoru na tomto počítači. Nic se neukládá a soubor ani pravidla na NAS se nemění. Při dalším spuštění (i jiným uživatelem) bude soubor znovu vyloučený.' 12.5 'Normal' $script:Col.Muted -Wrap -Margin '0,12,0,0'))
    $acts = New-IpPanel 'Horizontal' '0,18,0,0'; $acts.HorizontalAlignment = 'Right'
    $ok = New-IpButton 'Rozumím, povolit' 'Primary' $null '0,0,8,0'
    if ($Risk -eq 'err') { $ok.Background = Get-IpBrush $script:Col.Err; $ok.BorderBrush = Get-IpBrush $script:Col.Err }
    $ok.Add_Click({ param($s, $e) $s.Tag = 'yes'; [Windows.Window]::GetWindow($s).DialogResult = $true })
    $no = New-IpButton 'Zpět' 'Btn' $null; $no.IsCancel = $true
    [void]$acts.Children.Add($ok); [void]$acts.Children.Add($no); [void]$p.Children.Add($acts)
    $w.Content = $p
    return [bool]$w.ShowDialog()
}

function New-IpExceptionItem { param($F)
    $id = 'x-' + ([BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($F.Rel))) -replace '-', '').Substring(0, 10).ToLowerInvariant()
    return [pscustomobject]@{
        Id = $id; Name = [IO.Path]::GetFileName($F.Rel); Category = 'vyjimky'; Required = $false; Type = ''; Match = ''; VersionRegex = ''; VersionFormat = '$1'
        Rank = @(); Prefer = @(); Args = [pscustomobject]@{}; Winget = ''; Sources = @('nas'); Scope = 'machine'; Recommended = 'all'
        Why = "$($F.Reason) – povoleno ručně jen pro tuto relaci"; Detect = ''; DetectAppx = ''; Interactive = $true; NasInteractive = $true
        NasNeedsInternet = $false; KeepFileName = $true; CloseProcesses = @(); Dialogs = @(); Shortcut = ''; Pin = $false; TrustCertificates = $false; Notes = ''
        Exception = $true; Risk = $F.Risk; Rel = $F.Rel
        Candidate = [pscustomobject]@{ ItemId = $id; Rel = $F.Rel; Path = $F.Path; Root = $F.Root; Size = $F.Size; Modified = $F.Modified; Ext = $F.Ext; Kind = ''; Version = 'neznámá'; Product = ''; Company = ''; PerUser = $false; Recommended = $true }
    }
}

function Show-IpNasWindow {
    if ($script:S.NasWin) { $script:S.NasWin.Activate() | Out-Null; return }
    $w = New-Object Windows.Window
    $w.Title = 'Obsah NAS'; $w.Owner = $script:S.Win; $w.WindowStartupLocation = 'CenterOwner'
    $wa = [Windows.SystemParameters]::WorkArea; $w.Width = [Math]::Min(1100, $wa.Width - 80); $w.Height = $wa.Height - 60
    $w.Background = Get-IpBrush $script:Col.Bg; $w.FontFamily = 'Segoe UI'; $w.FontSize = 13.5
    $w.Add_Closed({ $script:S.NasWin = $null; Update-IpAll }); Set-IpOffscreen $w
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $script:S.NasWin = $w
    Update-IpNasWindow
    [void]$w.ShowDialog()
}

function Update-IpNasWindow {
    $w = $script:S.NasWin; if (-not $w) { return }
    $ix = $script:S.Index
    $d = New-IpPanel -Margin '26,20,26,30'
    [void]$d.Children.Add((New-IpText 'Obsah NAS' 22 'Bold'))
    [void]$d.Children.Add((New-IpText (($script:S.Settings.SourceRoots) -join ' · ') 12.5 'Normal' $script:Col.Muted -Font 'Consolas' -Margin '0,2,0,12'))
    if (-not $ix -or -not $ix.ScannedAt) { [void]$d.Children.Add((New-IpText 'Obsah NAS zatím není známý (NAS nedostupný a uložený index neexistuje).' 14 'Normal' $script:Col.Err -Wrap)) }
    else {
        if ($ix.FromCache) { [void]$d.Children.Add((New-IpBorder -Child (New-IpText ("NAS je odpojený – zobrazuji uložený index z {0:d. M. yyyy H:mm}. Z NAS teď nejde instalovat ani prohledávat." -f $ix.ScannedAt) 13.5 'Normal' $script:Col.Err -Wrap) -Bg $script:Col.ErrSoft -Radius 8 -Padding '12,10' -Margin '0,0,0,12')) }
        $stats = New-IpPanel 'Horizontal' '0,0,0,12'
        foreach ($s in @(@($ix.Stats.Files, 'souborů'), @($ix.Items.Count, 'programů rozpoznáno'), @(@($ix.Items.Values | Where-Object { @($_).Count -gt 1 }).Count, 've více verzích'), @(@($ix.Unrecognized).Count, 'nerozpoznaných'), @($script:S.Allowed.Count, 'výjimek v této relaci'))) {
            $sp = New-IpPanel; [void]$sp.Children.Add((New-IpText "$($s[0])" 22 'Bold')); [void]$sp.Children.Add((New-IpText $s[1] 12 'Normal' $script:Col.Muted))
            [void]$stats.Children.Add((New-IpBorder -Child $sp -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 8 -Padding '14,8' -Margin '0,0,10,0'))
        }
        [void]$d.Children.Add($stats)
        $rs = New-IpPanel 'Horizontal' '0,0,0,16'
        $rb = New-IpButton 'Prohledat znovu' 'Primary' $null '0,0,12,0' '12,5'; $rb.IsEnabled = -not $script:S.Checking -and -not (Test-IpBusy) -and (Get-IpState 'nas') -ne 'err'
        $rb.Add_Click({ Invoke-IpSafe { Start-IpHealthCheck -Rescan $true; Show-IpToast 'Prohledávám NAS…' } })
        [void]$rs.Children.Add($rb)
        [void]$rs.Children.Add((New-IpText ("Prohledáno {0:d. M. yyyy H:mm}. Offline, bez spouštění souborů – čtou se jen metadata, podpis a název." -f $ix.ScannedAt) 12.5 'Normal' $script:Col.Muted -Wrap))
        $rs.Children[1].VerticalAlignment = 'Center'
        [void]$d.Children.Add($rs)

        # výjimky
        [void]$d.Children.Add((New-IpText 'Vyloučené a nerozpoznané soubory' 16 'Bold' -Margin '0,6,0,6'))
        [void]$d.Children.Add((New-IpBorder -Child (New-IpText 'Vyloučený soubor můžete jako správce povolit. Povolení platí jen do zavření instalátoru na tomto počítači – nic se neukládá a soubory ani pravidla na NAS se nemění. Při dalším spuštění (i jiným uživatelem) bude soubor znovu vyloučený.' 13 'Normal' '' -Wrap) -Bg $script:Col.Surface2 -BorderColor $script:Col.Line2 -Thickness '1' -Radius 8 -Padding '12,10' -Margin '0,0,0,8'))
        $tbl = New-IpPanel
        foreach ($grp in @(@('VYLOUČENO PRAVIDLEM', @($ix.Excluded)), @('NEROZPOZNÁNO', @($ix.Unrecognized)))) {
            [void]$tbl.Children.Add((New-IpText $grp[0] 11 'SemiBold' $script:Col.Muted -Margin '12,10,0,4'))
            foreach ($f in $grp[1]) {
                $allowed = @($script:S.Allowed.Values | Where-Object Rel -eq $f.Rel).Count -gt 0
                $g = New-Object Windows.Controls.Grid; $g.Margin = '12,6,12,6'
                foreach ($wd in @('2*', '2*', '190')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
                $t1 = New-IpText $f.Rel 12 'Normal' '' -Font 'Consolas' -Wrap; [void]$g.Children.Add($t1)
                $t2 = New-IpPanel; [void]$t2.Children.Add((New-IpText $f.Reason 13 'Normal' '' -Wrap)); [void]$t2.Children.Add((New-IpText $(if ($f.Risk -eq 'err') { 'VYSOKÉ RIZIKO' } else { 'RIZIKO' }) 10.5 'Bold' $(if ($f.Risk -eq 'err') { $script:Col.Err } else { $script:Col.Warn })))
                $t2.Margin = '12,0,12,0'; [Windows.Controls.Grid]::SetColumn($t2, 1); [void]$g.Children.Add($t2)
                if ($allowed) {
                    $a = New-IpPanel; [void]$a.Children.Add((New-IpChip 'povoleno v této relaci' $script:Col.Warn $script:Col.WarnSoft))
                    $bb = New-IpButton 'Znovu vyloučit' 'Link' $f.Rel; $bb.HorizontalAlignment = 'Left'; $bb.Padding = '0,2'
                    $bb.Add_Click({ param($s, $e) Invoke-IpSafe {
                            $k = @($script:S.Allowed.Keys | Where-Object { $script:S.Allowed[$_].Rel -eq $s.Tag })[0]
                            [void]$script:S.Sel.Remove($k); $script:S.Allowed.Remove($k)
                            Write-IpLog -Settings $script:S.Settings -Message "Výjimka zrušena: $($s.Tag)"; Show-IpToast "»$([IO.Path]::GetFileName($s.Tag))« je znovu vyloučené."; Update-IpNasWindow; Update-IpAll } })
                    [void]$a.Children.Add($bb)
                }
                else {
                    $a = New-IpButton 'Povolit pro tuto relaci…' 'Btn' $f '' '10,4'; $a.HorizontalAlignment = 'Left'; $a.VerticalAlignment = 'Top'
                    $a.IsEnabled = (Get-IpState 'nas') -ne 'err' -and -not (Test-IpBusy)
                    $a.Add_Click({ param($s, $e) Invoke-IpSafe {
                            $f = $s.Tag
                            $txt = if ($f.Kind -eq 'unrecognized') { 'Skript soubor nerozpoznal. Nelze ověřit, co nainstaluje, ani zda je podepsaný výrobcem. Spustí se s vlastním oknem instalátoru, bez tiché instalace.' } else { "Soubor je vyloučený: $($f.Reason). Spustí se s vlastním oknem instalátoru." }
                            if (Show-IpConfirm -Title $f.Rel -Text $txt -Risk $f.Risk) {
                                $it = New-IpExceptionItem $f; $script:S.Allowed[$it.Id] = $it
                                Write-IpLog -Settings $script:S.Settings -Level Warning -Message "Výjimka povolena pro tuto relaci: $($f.Rel) ($($f.Reason))"
                                Show-IpToast "»$($it.Name)« povoleno jen pro tuto relaci. Najdete ho vpravo v kategorii $($script:ExCategory)."
                                Update-IpNasWindow; Update-IpAll
                            } } })
                }
                [Windows.Controls.Grid]::SetColumn($a, 2); [void]$g.Children.Add($a)
                [void]$tbl.Children.Add((New-IpBorder -Child $g -BorderColor $script:Col.Line2 -Thickness '0,1,0,0' -Bg $(if ($allowed) { '#FDF6EC' } else { 'Transparent' })))
            }
        }
        [void]$d.Children.Add((New-IpBorder -Child $tbl -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10 -Padding '0,0,0,6'))

        # rozpoznané
        [void]$d.Children.Add((New-IpText 'Rozpoznané programy' 16 'Bold' -Margin '0,20,0,6'))
        $rt = New-IpPanel
        foreach ($it in $script:S.Catalog.Items) {
            $cs = @(Get-IpCandidates -Index $ix -ItemId $it.Id); if (-not $cs.Count) { continue }
            $g = New-Object Windows.Controls.Grid; $g.Margin = '12,6,12,6'
            foreach ($wd in @('220', '*', '170')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }
            [void]$g.Children.Add((New-IpText $it.Name 13.5 'SemiBold'))
            $vs = New-IpPanel; [Windows.Controls.Grid]::SetColumn($vs, 1)
            foreach ($c in $cs) { [void]$vs.Children.Add((New-IpText ("{0}{1}   {2}" -f $c.Version, $(if ($c.Recommended -and $cs.Count -gt 1) { ' ★' } else { '' }), $c.Rel) 12 'Normal' '' -Font 'Consolas' -Wrap)) }
            [void]$g.Children.Add($vs)
            $how = switch ($cs[0].Kind) { 'msi' { 'MSI: název a verze produktu' } 'msix' { 'manifest balíčku' } 'font' { 'název rodiny písma' } default { "metadata EXE ($($cs[0].Kind))" } }
            $ht = New-IpText $how 12 'Normal' $script:Col.Muted; [Windows.Controls.Grid]::SetColumn($ht, 2); [void]$g.Children.Add($ht)
            [void]$rt.Children.Add((New-IpBorder -Child $g -BorderColor $script:Col.Line2 -Thickness '0,1,0,0'))
        }
        [void]$d.Children.Add((New-IpBorder -Child $rt -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10))
        [void]$d.Children.Add((New-IpText '★ doporučená verze (nejnovější stabilní)' 12 'Normal' $script:Col.Muted -Margin '4,6,0,0'))

        [void]$d.Children.Add((New-IpText 'Vynechané složky' 16 'Bold' -Margin '0,20,0,6'))
        foreach ($f in @($ix.ExcludedFolders)) { [void]$d.Children.Add((New-IpText "$($f.Rel) – $($f.Reason)" 13 'Normal' '' -Wrap -Margin '4,2,0,2')) }
    }
    $sv = New-Object Windows.Controls.ScrollViewer; $sv.Content = $d
    $w.Content = $sv
}

#endregion

#region Jazyk uživatelů (doplňkové okno z horní lišty)

$script:LangLoadJob = {
    param($Settings, $Queue)
    try {
        $langs = Read-IpLanguages -Settings $Settings
        $users = @(Get-IpUserProfiles -Settings $Settings -Languages $langs)
        $Queue.Enqueue([pscustomobject]@{ Kind = 'langusers'; Languages = $langs; Users = $users; Machine = (Get-IpMachineLanguageInfo); Assign = (Read-IpLanguageAssignments -Settings $Settings); Error = '' })
    }
    catch { $Queue.Enqueue([pscustomobject]@{ Kind = 'langusers'; Languages = $null; Users = @(); Machine = $null; Assign = @{}; Error = $_.Exception.Message }) }
}
$script:LangFindJob = {
    param($Languages, $Query, $Queue)
    try { $Queue.Enqueue([pscustomobject]@{ Kind = 'langfound'; Users = @(Find-IpAdUsers -Languages $Languages -Query $Query); Error = '' }) }
    catch { $Queue.Enqueue([pscustomobject]@{ Kind = 'langfound'; Users = @(); Error = $_.Exception.Message }) }
}
$script:LangSaveJob = {
    param($Settings, $Changes, $Parts, $Machine, $Queue)
    [void](Invoke-IpLanguageChanges -Settings $Settings -Changes $Changes -Parts $Parts -Machine $Machine -Queue $Queue)
}
$script:LangBrokerJob = {
    param($Settings, $Changes, $Parts, $Machine, $Queue)
    Invoke-IpBrokerLanguageRequest -Settings $Settings -Changes $Changes -Parts $Parts -Machine $Machine -Queue $Queue
}

function Get-IpLangMode {
    # admin  = jako správce, vše provede okno
    # broker = bez práv správce, vše přes systémovou úlohu (settings.json languageForAll = true)
    # self   = bez práv správce, jen vlastní účet (languageForAll = false)
    # view   = jen prohlížení
    if ($script:S.IsAdmin) { return 'admin' }
    if ($script:S.UseBroker) { if ($script:S.Settings.LanguageForAll) { return 'broker' } return 'self' }
    return 'view'
}
function Test-IpLangFull { return (Get-IpLangMode) -in @('admin', 'broker') }

#region Mazání profilů
$script:ProfDelJob = {
    param($Settings, $Targets, $Protect, $Queue)
    [void](Remove-IpUserProfiles -Settings $Settings -Targets $Targets -Protect $Protect -Queue $Queue)
}
$script:ProfBrokerJob = {
    param($Settings, $Body, $Queue)
    Invoke-IpBrokerLanguageRequest -Settings $Settings -Body $Body -Queue $Queue
}
function Get-IpDelMode {
    # admin = okno jako správce; broker = přes systémovou úlohu (settings.json profileDeleteForAll); none = nejde
    if ($script:S.IsAdmin) { return 'admin' }
    if ($script:S.UseBroker -and $script:S.Settings.ProfileDeleteForAll) { return 'broker' }
    return 'none'
}
function Get-IpProfileProtected { param($U)
    # Důvod, proč profil smazat nejde ('' = jde).
    $L = $script:S.L
    if ($U.Sid -eq $L.SelfSid) { return 'je to účet, pod kterým jste přihlášený' }
    if ($script:S.User -and $U.Sid -eq $script:S.User.Sid) { return 'uživatel je přihlášený u tohoto počítače' }
    if ($U.LoggedOn) { return 'uživatel je přihlášený' }
    if ($U.Loaded) { return 'profil se právě používá' }
    if (-not $U.ProfilePath) { return 'na tomto PC nemá profil' }
    return ''
}
function Show-IpDeleteConfirm { param([object[]] $Users)
    # Vrací $null (zpět) nebo @{ DeleteAccount = bool }.
    $w = New-Object Windows.Window
    $w.Title = 'Smazat profily'; $w.Owner = $script:S.L.Win; $w.WindowStartupLocation = 'CenterOwner'; $w.SizeToContent = 'Height'; $w.Width = 620; $w.ResizeMode = 'NoResize'
    $w.FontFamily = 'Segoe UI'; $w.FontSize = 13.5; $w.Background = Get-IpBrush $script:Col.Surface
    $p = New-IpPanel -Margin '22,20,22,20'
    $h = New-IpPanel 'Horizontal'; [void]$h.Children.Add((New-IpStateIcon 'err' 24)); [void]$h.Children.Add((New-IpText "Smazat $($Users.Count) $(Get-IpPlural $Users.Count 'profil' 'profily' 'profilů')?" 17 'Bold' -Margin '10,0,0,0')); [void]$p.Children.Add($h)
    [void]$p.Children.Add((New-IpText 'Z tohoto počítače se nevratně smažou dokumenty, plocha, stažené soubory a nastavení programů těchto uživatelů. Soubory uložené na serveru / OneDrive zůstanou.' 13.5 'Normal' '' -Wrap -Margin '0,12,0,8'))
    foreach ($u in $Users) {
        $k = @{ domain = 'doménový – účet v AD zůstane'; local = 'místní'; aad = 'Entra ID – účet zůstane' }[$u.Kind]
        [void]$p.Children.Add((New-IpText "•  $($u.Name)  ($k)  –  $($u.ProfilePath)" 13 'Normal' '' -Wrap -Margin '6,2,0,0'))
    }
    $ch = New-Object Windows.Controls.CheckBox; $ch.Content = 'U místních účtů smazat i samotný účet (ne jen profil)'; $ch.Margin = '0,14,0,0'
    $ch.Visibility = if (@($Users | Where-Object Kind -eq 'local').Count) { 'Visible' } else { 'Collapsed' }
    [void]$p.Children.Add($ch)
    $acts = New-IpPanel 'Horizontal' '0,18,0,0'; $acts.HorizontalAlignment = 'Right'
    $ok = New-IpButton 'Smazat' 'Primary' $null '0,0,8,0'; $ok.Background = Get-IpBrush $script:Col.Err; $ok.BorderBrush = Get-IpBrush $script:Col.Err
    $ok.Add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).DialogResult = $true })
    $no = New-IpButton 'Zpět' 'Btn' $null; $no.IsCancel = $true
    [void]$acts.Children.Add($ok); [void]$acts.Children.Add($no); [void]$p.Children.Add($acts)
    $w.Content = $p
    if (-not [bool]$w.ShowDialog()) { return $null }
    return @{ DeleteAccount = [bool]$ch.IsChecked }
}
function Remove-IpSelectedProfiles {
    param([switch] $ThenSave)
    $L = $script:S.L
    if ($L.Busy) { return }
    if (Test-IpBusy) { Show-IpToast 'Počkejte na dokončení instalace programů.'; return }
    $mode = Get-IpDelMode; if ($mode -eq 'none') { return }
    $users = @(Get-IpLangUsers | Where-Object { $L.Del.Contains($_.Sid) -and -not (Get-IpProfileProtected $_) })
    if (-not $users.Count) { $L.Del.Clear(); Update-IpLangWindow; return }
    $c = Show-IpDeleteConfirm -Users $users
    if (-not $c) { return }
    $targets = @($users | ForEach-Object { @{ Sid = $_.Sid; DeleteAccount = $c.DeleteAccount } })
    foreach ($u in $users) { [void]$L.Pending.Remove($u.Sid) }   # mazanému uživateli jazyk nenastavovat
    $L.ThenSave = [bool]$ThenSave -and ($L.Pending.Count -gt 0 -or @($L.MachineSel.Values | Where-Object { $_ }).Count -gt 0)
    $L.Log.Clear(); $L.Done = $null; $L.Busy = $true
    Write-IpLog -Settings $script:S.Settings -Level Warning -Message ("Profily – mažu: " + (($users | ForEach-Object Name) -join ', ') + $(if ($c.DeleteAccount) { ' (i místní účty)' } else { '' }))
    if ($mode -eq 'admin') {
        $protect = @($L.SelfSid) + @($(if ($script:S.User) { $script:S.User.Sid }))
        Start-IpJob -Kind 'langsave' -Script $script:ProfDelJob -Params @{ Settings = $script:S.Settings; Targets = $targets; Protect = $protect; Queue = $script:S.Queue }
    }
    else {
        Start-IpJob -Kind 'langsave' -Script $script:ProfBrokerJob -Params @{ Settings = $script:S.Settings; Body = [ordered]@{ Kind = 'profiles'; Targets = $targets }; Queue = $script:S.Queue }
    }
    Update-IpLangWindow
}
#endregion
function Test-IpLangEditable { param($U)
    switch (Get-IpLangMode) { 'admin' { return $true } 'broker' { return $true } 'self' { return $U.Sid -eq $script:S.L.SelfSid } default { return $false } }
}
function Get-IpLangName { param([string] $Id)
    $d = $script:S.L.Data
    if ($d -and $d.Languages.ById.ContainsKey($Id)) { return $d.Languages.ById[$Id].Name }
    return $Id
}

function Start-IpLangLoad {
    if (@($script:S.Jobs | Where-Object Kind -eq 'langload').Count) { return }
    $script:S.L.Loading = $true
    Start-IpJob -Kind 'langload' -Script $script:LangLoadJob -Params @{ Settings = $script:S.Settings; Queue = $script:S.Queue }
}

function Show-IpLanguageWindow {
    $L = $script:S.L
    if ($L.Win) { $L.Win.Activate() | Out-Null; return }
    $w = New-Object Windows.Window
    $w.Title = 'Jazyk uživatelů'; $w.Owner = $script:S.Win; $w.WindowStartupLocation = 'CenterOwner'
    $wa = [Windows.SystemParameters]::WorkArea; $w.Width = [Math]::Min(1280, $wa.Width - 60); $w.Height = $wa.Height - 60
    $w.Background = Get-IpBrush $script:Col.Bg; $w.FontFamily = 'Segoe UI'; $w.FontSize = 13.5
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $w.Add_Closed({
            $L = $script:S.L; $L.Win = $null
            if (-not $L.Busy) { $L.Pending = @{}; $L.MachineSel = @{ SystemLocale = ''; TimeZone = '' }; $L.Extra = [ordered]@{}; $L.Found = @(); $L.Done = $null; $L.Log.Clear(); $L.Del.Clear() }
        })
    Set-IpOffscreen $w
    $L.Win = $w
    if (-not $L.Loading) { Start-IpLangLoad }
    Update-IpLangWindow
    [void]$w.ShowDialog()
}

function New-IpCombo { param([object[]] $Options, [string] $Selected, $Tag, [bool] $Enabled, [scriptblock] $OnChange, [double] $Width = 230)
    # Options: @( @(hodnota, text), ... ). Hodnoty jsou vždy řetězce ('__keep' = beze změny).
    $cb = New-Object Windows.Controls.ComboBox; $cb.Padding = '6,4'; $cb.Width = $Width; $cb.VerticalAlignment = 'Top'
    $i = 0; $sel = 0
    foreach ($o in $Options) {
        $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = [string]$o[1]; $it.Tag = [string]$o[0]
        [void]$cb.Items.Add($it); if ([string]$o[0] -eq $Selected) { $sel = $i }; $i++
    }
    $cb.SelectedIndex = $sel; $cb.Tag = $Tag; $cb.IsEnabled = $Enabled
    $cb.Add_SelectionChanged($OnChange)
    return $cb
}

function Get-IpLangUsers {
    # Uživatelé PC + uživatelé přidaní z AD v tomto okně.
    $L = $script:S.L
    $list = @(); if ($L.Data) { $list = @($L.Data.Users) }
    foreach ($x in $L.Extra.Values) { if (-not @($list | Where-Object Sid -eq $x.Sid).Count) { $list += $x } }
    return $list
}

function Update-IpLangFooter {
    $L = $script:S.L
    if (-not $L.SumText) { return }
    $n = $L.Pending.Count; $m = @($L.MachineSel.Values | Where-Object { $_ }).Count
    $x = if ((Get-IpDelMode) -ne 'none') { $L.Del.Count } else { 0 }
    $langOk = ($n + $m) -gt 0 -and $L.Parts.Count -gt 0 -and (Get-IpLangMode) -ne 'view'
    $what = @()
    if ($n) { $what += "jazyk: $n $(Get-IpPlural $n 'uživatel' 'uživatelé' 'uživatelů')" }
    if ($m) { $what += "celý počítač: $m" }
    if ($x) { $what += "smazat: $x $(Get-IpPlural $x 'profil' 'profily' 'profilů')" }
    $L.SumText.Text = if ($L.Busy) { 'Pracuji… (okno můžete nechat otevřené)' }
    elseif (-not $what.Count) { 'Vyberte jazyk u uživatele nebo zaškrtněte smazat profil. Nic se nezmění, dokud nekliknete na tlačítko vpravo.' }
    else { 'Změny – ' + ($what -join ' · ') + ' – zatím neuloženo.' }
    # Jedno tlačítko pro vše: smazání (s potvrzením) a/nebo uložení jazyka.
    $L.SaveBtn.Content = if ($L.Busy) { 'Pracuji…' } elseif ($x -and -not ($n + $m)) { "Smazat vybrané ($x)…" } elseif ($x) { 'Smazat a uložit…' } else { 'Uložit a nastavit' }
    $col = if ($x -and -not $L.Busy) { $script:Col.Err } else { $script:Col.Accent }
    $L.SaveBtn.Background = Get-IpBrush $col; $L.SaveBtn.BorderBrush = Get-IpBrush $col
    $L.SaveBtn.IsEnabled = -not $L.Busy -and ($x -gt 0 -or $langOk) -and -not (Test-IpBusy)
}

function Save-IpLanguage {
    param([switch] $KeepLog)
    $L = $script:S.L
    if ($L.Busy) { return }
    if (Test-IpBusy) { Show-IpToast 'Počkejte na dokončení instalace programů.'; return }
    # Nejdřív smazání (s potvrzením); změny jazyka se pak uloží automaticky hned po něm.
    if (-not $KeepLog -and $L.Del.Count -and (Get-IpDelMode) -ne 'none') {
        $more = $L.Pending.Count -gt 0 -or @($L.MachineSel.Values | Where-Object { $_ }).Count -gt 0
        Remove-IpSelectedProfiles -ThenSave:$more
        return
    }
    $parts = @($L.Parts)
    $mode = Get-IpLangMode
    if ($mode -eq 'view') { return }
    $byId = @{}; foreach ($u in Get-IpLangUsers) { $byId[$u.Sid] = $u }
    $sids = @($L.Pending.Keys); if ($mode -eq 'self') { $sids = @($sids | Where-Object { $_ -eq $L.SelfSid }) }
    $changes = @(foreach ($sid in $sids) {
            $u = $byId[$sid]
            @{ Sid = $sid; Account = $(if ($sid -eq 'default') { 'default' } elseif ($u) { $u.Name } else { $sid }); ProfilePath = $(if ($u) { [string]$u.ProfilePath } else { '' }); Language = [string]$L.Pending[$sid] }
        })
    $machine = if ($mode -eq 'self') { @{ SystemLocale = ''; TimeZone = '' } } else { @{ SystemLocale = $L.MachineSel.SystemLocale; TimeZone = $L.MachineSel.TimeZone } }
    if (-not $changes.Count -and -not ($machine.SystemLocale -or $machine.TimeZone)) { return }
    if ($KeepLog) { $L.PrevDone = $L.Done } else { $L.Log.Clear() }
    $L.Done = $null; $L.Busy = $true
    Write-IpLog -Settings $script:S.Settings -Message ('Jazyk – ukládám: ' + (($changes | ForEach-Object { "$($_.Account)=$(if ($_.Language) { $_.Language } else { 'zrušit' })" }) -join ', ') + " · části: $($parts -join ',')" + $(if ($mode -ne 'admin') { ' · přes systémovou úlohu' } else { '' }))
    # Jako správce provede změny okno samo, bez práv správce systémová úloha (ta si účty ověří sama).
    $job = if ($mode -eq 'admin') { $script:LangSaveJob } else { $script:LangBrokerJob }
    Start-IpJob -Kind 'langsave' -Script $job -Params @{ Settings = $script:S.Settings; Changes = $changes; Parts = $parts; Machine = $machine; Queue = $script:S.Queue }
    Update-IpLangWindow
}

function New-IpLangUserRow { param($U, [object[]] $LangOptions)
    $L = $script:S.L
    $edit = (Test-IpLangEditable $U) -and -not $L.Busy
    $g = New-Object Windows.Controls.Grid; $g.Margin = '14,10,14,10'
    foreach ($wd in @('2.3*', '2*', '2*', '240')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; $g.ColumnDefinitions.Add($cd) }

    # 1 uživatel
    $c1 = New-IpPanel
    $self = $U.Sid -eq $L.SelfSid
    [void]$c1.Children.Add((New-IpText ($U.Name + $(if ($self) { '  (vy)' } else { '' })) 14 'SemiBold' -Wrap))
    $ad = $U.Ad
    $sub = @(); if ($ad) { foreach ($v in @($ad.DisplayName, $ad.Department, $ad.City)) { if ($v) { $sub += $v } } }
    if ($sub.Count) { [void]$c1.Children.Add((New-IpText ($sub -join ' · ') 12.5 'Normal' $script:Col.Muted -Wrap)) }
    $chips = New-IpPanel 'Horizontal' '0,4,0,0'
    switch ($U.Kind) {
        'domain' { [void]$chips.Children.Add((New-IpChip 'DOMÉNOVÝ' $script:Col.Accent $script:Col.AccentSoft 'Účet z domény (Active Directory)')) }
        'local' { [void]$chips.Children.Add((New-IpChip 'MÍSTNÍ' $script:Col.Muted $script:Col.Surface2 'Účet jen na tomto počítači')) }
        'aad' { [void]$chips.Children.Add((New-IpChip 'ENTRA ID' $script:Col.Accent $script:Col.AccentSoft 'Účet Microsoft Entra ID (Azure AD)')) }
        default { [void]$chips.Children.Add((New-IpChip 'NEOVĚŘENÝ' $script:Col.Warn $script:Col.WarnSoft 'Typ účtu nejde zjistit')) }
    }
    if (-not $U.Resolved) { [void]$chips.Children.Add((New-IpChip 'ÚČET NEJDE OVĚŘIT' $script:Col.Warn $script:Col.WarnSoft 'Doména není dostupná nebo účet už neexistuje. Zobrazen název složky profilu.')) }
    if ($U.LoggedOn) { [void]$chips.Children.Add((New-IpChip 'PŘIHLÁŠEN' $script:Col.Ok $script:Col.OkSoft)) }
    if ($U.FromAd -and -not $U.ProfilePath) { [void]$chips.Children.Add((New-IpChip 'ZATÍM BEZ PROFILU' $script:Col.Muted $script:Col.Surface2 'Na tomto PC se ještě nepřihlásil – jazyk se nastaví při prvním přihlášení.')) }
    [void]$c1.Children.Add($chips)
    [void]$g.Children.Add($c1)

    # 2 teď
    $c2 = New-IpPanel; $c2.Margin = '12,0,12,0'; [Windows.Controls.Grid]::SetColumn($c2, 1)
    if ($U.Current) {
        $ui = if ($U.Current.Ui) { $U.Current.Ui } else { 'podle systému' }
        [void]$c2.Children.Add((New-IpText "Windows: $ui" 13))
        [void]$c2.Children.Add((New-IpText "Formáty: $($U.Current.Culture)" 13))
        if (@($U.Current.Languages).Count) { [void]$c2.Children.Add((New-IpText "Klávesnice: $(@($U.Current.Languages) -join ', ')" 13 'Normal' '' -Wrap)) }
    }
    else { [void]$c2.Children.Add((New-IpText 'Není přihlášen – aktuální jazyk nejde přečíst.' 13 'Normal' $script:Col.Muted -Wrap)) }
    if ($U.LastUse) { [void]$c2.Children.Add((New-IpText ("Naposledy: {0:d. M. yyyy}" -f $U.LastUse) 12 'Normal' $script:Col.Muted -Margin '0,2,0,0')) }
    [void]$g.Children.Add($c2)

    # 3 přiřazení a návrh
    $c3 = New-IpPanel; $c3.Margin = '0,0,12,0'; [Windows.Controls.Grid]::SetColumn($c3, 2)
    $a = $U.Assigned
    if ($a) {
        [void]$c3.Children.Add((New-IpText "Přiřazeno: $($a.Name)" 13 'SemiBold' -Wrap))
        if ($U.Current -and $U.Current.Stamp -eq $a.Stamp) {
            $when = try { ' ' + ([datetime]::Parse($U.Current.AppliedAt)).ToString('d. M. yyyy H:mm') } catch { '' }
            if ($U.Current.Result -eq 'ui-missing') { [void]$c3.Children.Add((New-IpChip 'JAZYK WINDOWS CHYBÍ' $script:Col.Warn $script:Col.WarnSoft 'Klávesnice a formáty nastaveny, jazykový balíček Windows na PC není.')) }
            else { [void]$c3.Children.Add((New-IpText "nastaveno$when" 12.5 'Normal' $script:Col.Ok)) }
        }
        else { [void]$c3.Children.Add((New-IpText 'nastaví se při příštím přihlášení' 12.5 'Normal' $script:Col.Muted -Wrap)) }
    }
    $sg = $U.Suggested
    if ($sg -and (-not $a -or $a.Language -ne $sg.Id)) {
        $sp = New-IpPanel 'Horizontal' '0,4,0,0'
        [void]$sp.Children.Add((New-IpText "Návrh: $(Get-IpLangName $sg.Id)" 13 'Normal' $script:Col.Accent))
        if ($edit) {
            $b = New-IpButton 'použít' 'Link' @($U.Sid, $sg.Id) '6,0,0,0'
            $b.Add_Click({ param($s, $e) Invoke-IpSafe { $script:S.L.Pending[[string]$s.Tag[0]] = [string]$s.Tag[1]; Update-IpLangWindow } })
            [void]$sp.Children.Add($b)
        }
        [void]$c3.Children.Add($sp)
        [void]$c3.Children.Add((New-IpText "($($sg.Why))" 12 'Normal' $script:Col.Muted -Wrap))
    }
    if (-not $a -and -not $sg) { [void]$c3.Children.Add((New-IpText 'bez přiřazení' 12.5 'Normal' $script:Col.Muted)) }
    [void]$g.Children.Add($c3)

    # 4 výběr
    $opts = @(, @('__keep', $(if ($a) { "beze změny ($($a.Language))" } else { '— beze změny —' }))) + $LangOptions
    if ($a) { $opts += , @('__none', '✕ zrušit přiřazení') }
    $selv = if ($L.Pending.ContainsKey($U.Sid)) { if ($L.Pending[$U.Sid]) { [string]$L.Pending[$U.Sid] } else { '__none' } } else { '__keep' }
    $cb = New-IpCombo -Options $opts -Selected $selv -Tag $U.Sid -Enabled $edit -OnChange { param($s, $e) Invoke-IpSafe {
            $v = [string]$s.SelectedItem.Tag; $sid = [string]$s.Tag
            if ($v -eq '__keep') { [void]$script:S.L.Pending.Remove($sid) } elseif ($v -eq '__none') { $script:S.L.Pending[$sid] = '' } else { $script:S.L.Pending[$sid] = $v }
            Update-IpLangFooter } }
    if (-not $edit -and -not $L.Busy) { $cb.ToolTip = 'Jazyk ostatních uživatelů nastaví IT (aplikace spuštěná jako správce).' }
    $c4 = New-IpPanel; [void]$c4.Children.Add($cb)
    if ((Get-IpDelMode) -ne 'none') {
        $why = Get-IpProfileProtected $U
        $dc = New-Object Windows.Controls.CheckBox; $dc.Content = 'smazat profil'; $dc.Tag = $U.Sid; $dc.Margin = '2,8,0,0'
        $dc.IsChecked = $L.Del.Contains($U.Sid); $dc.IsEnabled = -not $why -and -not $L.Busy
        $dc.ToolTip = if ($why) { "Nejde smazat: $why." } else { 'Smaže profil uživatele na tomto PC (dokumenty, plocha, nastavení). Potvrzuje se tlačítkem Smazat vybrané.' }
        $dc.Add_Click({ param($s, $e) Invoke-IpSafe { if ($s.IsChecked) { [void]$script:S.L.Del.Add([string]$s.Tag) } else { [void]$script:S.L.Del.Remove([string]$s.Tag) }; Update-IpLangWindow } })
        if ($dc.IsChecked) { $dc.Foreground = Get-IpBrush $script:Col.Err; $dc.FontWeight = 'SemiBold' }
        [void]$c4.Children.Add($dc)
    }
    [Windows.Controls.Grid]::SetColumn($c4, 3); [void]$g.Children.Add($c4)

    $bg = if ($L.Del.Contains($U.Sid)) { '#FCEFED' } elseif ($L.Pending.ContainsKey($U.Sid)) { '#F2F9FA' } else { 'Transparent' }
    return (New-IpBorder -Child $g -BorderColor $script:Col.Line2 -Thickness '0,1,0,0' -Bg $bg)
}

function Update-IpLangWindow {
    $L = $script:S.L; $w = $L.Win; if (-not $w) { return }
    $off = if ($L.Scroll) { $L.Scroll.VerticalOffset } else { 0 }
    $mode = Get-IpLangMode
    $data = $L.Data
    $mi = if ($data) { $data.Machine } else { $null }

    $d = New-IpPanel -Margin '26,20,26,24'
    [void]$d.Children.Add((New-IpText 'Jazyk a region uživatelů' 22 'Bold'))
    if ($mi) {
        $dom = if ($mi.PartOfDomain) { "v doméně $($mi.Domain)" } else { "není v doméně (pracovní skupina $($mi.Domain))" }
        [void]$d.Children.Add((New-IpText "Počítač $($mi.Computer) · $dom · jazyky Windows na PC: $(@($mi.UiLanguages) -join ', ')" 12.5 'Normal' $script:Col.Muted -Wrap -Margin '0,2,0,12'))
    }
    else { [void]$d.Children.Add((New-IpText "Počítač $([Environment]::MachineName)" 12.5 'Normal' $script:Col.Muted -Margin '0,2,0,12')) }
    [void]$d.Children.Add((New-IpBorder -Child (New-IpText 'Vyberte uživateli jazyk. Podle něj se nastaví klávesnice, jazyk Windows a formáty (datum, čísla, měna) a ve stejném jazyce se instalují programy z internetu (winget, Office). Přihlášenému uživateli se nastaví hned – jazyk Windows se změní po odhlášení. Ostatním při příštím přihlášení. Nastavení se použije jednou, pak si ho uživatel může změnit sám.' 13 'Normal' '' -Wrap) -Bg $script:Col.Surface2 -BorderColor $script:Col.Line2 -Thickness '1' -Radius 8 -Padding '12,10' -Margin '0,0,0,10'))
    if ($mode -eq 'self') { [void]$d.Children.Add((New-IpBorder -Child (New-IpText 'Bez práv správce můžete nastavit jen svůj účet (provede to systémová úloha, bez hesla). Ostatním uživatelům a celému počítači nastaví jazyk IT – aplikace spuštěná jako správce.' 13 'Normal' $script:Col.Warn -Wrap) -Bg $script:Col.WarnSoft -Radius 8 -Padding '12,10' -Margin '0,0,0,10')) }
    if ($mode -eq 'broker') { [void]$d.Children.Add((New-IpText 'Změny provede systémová úloha – heslo správce není potřeba.' 12.5 'Normal' $script:Col.Muted -Wrap -Margin '0,0,0,10')) }
    if ($mode -eq 'view') { [void]$d.Children.Add((New-IpBorder -Child (New-IpText 'Aplikace neběží jako správce a systémová úloha na PC není – jazyk jde jen prohlížet.' 13 'Normal' $script:Col.Err -Wrap) -Bg $script:Col.ErrSoft -Radius 8 -Padding '12,10' -Margin '0,0,0,10')) }
    if ($L.Error) { [void]$d.Children.Add((New-IpBorder -Child (New-IpText "Seznam uživatelů nejde načíst: $($L.Error)" 13 'Normal' $script:Col.Err -Wrap) -Bg $script:Col.ErrSoft -Radius 8 -Padding '12,10' -Margin '0,0,0,10')) }

    if (-not $data) {
        [void]$d.Children.Add((New-IpText $(if ($L.Loading) { 'Načítám uživatele počítače a údaje z domény…' } else { 'Údaje nejsou k dispozici.' }) 14 'Normal' $script:Col.Muted -Margin '0,10,0,0'))
    }
    else {
        $langs = $data.Languages
        $langOpts = @(foreach ($li in $langs.Items) { , @($li.Id, "$($li.Name)  ·  $($li.Id)") })

        # co nastavit
        $pp = New-IpPanel 'Horizontal' '0,4,0,12'
        [void]$pp.Children.Add((New-IpText 'Podle jazyka nastavit:' 13 'SemiBold' -Margin '0,0,14,0'))
        foreach ($p in @(@('keyboard', 'Klávesnice a jazyky zadávání'), @('ui', 'Jazyk Windows (menu, okna)'), @('region', 'Formáty a oblast (datum, čísla, měna)'))) {
            $ch = New-Object Windows.Controls.CheckBox; $ch.Content = $p[1]; $ch.Tag = $p[0]; $ch.IsChecked = $L.Parts.Contains($p[0]); $ch.Margin = '0,0,18,0'; $ch.VerticalAlignment = 'Center'
            $ch.IsEnabled = $mode -ne 'view' -and -not $L.Busy
            $ch.Add_Click({ param($s, $e) Invoke-IpSafe { if ($s.IsChecked) { [void]$script:S.L.Parts.Add([string]$s.Tag) } else { [void]$script:S.L.Parts.Remove([string]$s.Tag) }; Update-IpLangFooter } })
            [void]$pp.Children.Add($ch)
        }
        [void]$d.Children.Add($pp)

        # uživatelé
        $users = @(Get-IpLangUsers)
        $hd = New-Object Windows.Controls.DockPanel; $hd.Margin = '0,6,0,6'
        $hb = New-IpPanel 'Horizontal'; [Windows.Controls.DockPanel]::SetDock($hb, 'Right')
        if (Test-IpLangFull) {
            $nSug = @($users | Where-Object { $_.Suggested -and (-not $_.Assigned -or $_.Assigned.Language -ne $_.Suggested.Id) }).Count
            if ($nSug) {
                $bs = New-IpButton "Použít návrhy z AD ($nSug)" 'Btn' $null '0,0,8,0' '10,4'; $bs.IsEnabled = -not $L.Busy
                $bs.ToolTip = 'Každému uživateli s údaji v AD vybere jazyk podle preferovaného jazyka nebo země.'
                $bs.Add_Click({ Invoke-IpSafe { foreach ($u in Get-IpLangUsers) { if ($u.Suggested -and (-not $u.Assigned -or $u.Assigned.Language -ne $u.Suggested.Id)) { $script:S.L.Pending[$u.Sid] = $u.Suggested.Id } }; Update-IpLangWindow } })
                [void]$hb.Children.Add($bs)
            }
        }
        if ($L.Del.Count) {
            $bd = New-IpButton "Smazat vybrané profily ($($L.Del.Count))…" 'Primary' $null '0,0,8,0' '10,4'; $bd.IsEnabled = -not $L.Busy
            $bd.Background = Get-IpBrush $script:Col.Err; $bd.BorderBrush = Get-IpBrush $script:Col.Err
            $bd.Add_Click({ Invoke-IpSafe { Remove-IpSelectedProfiles } })
            [void]$hb.Children.Add($bd)
        }
        $br = New-IpButton 'Načíst znovu' 'Btn' $null '' '10,4'; $br.IsEnabled = -not $L.Loading -and -not $L.Busy
        $br.Add_Click({ Invoke-IpSafe { Start-IpLangLoad; Update-IpLangWindow } })
        [void]$hb.Children.Add($br); [void]$hd.Children.Add($hb)
        $nd = @($users | Where-Object Kind -eq 'domain').Count
        $ht = New-IpText "Uživatelé tohoto počítače  ·  $($users.Count) ($nd doménových)$(if ($L.Loading) { '  ·  načítám…' })" 16 'Bold'; $ht.VerticalAlignment = 'Center'
        [void]$hd.Children.Add($ht); [void]$d.Children.Add($hd)

        $tbl = New-IpPanel
        $hg = New-Object Windows.Controls.Grid; $hg.Margin = '14,8,14,4'
        $i = 0; foreach ($x in @(@('2.3*', 'UŽIVATEL'), @('2*', 'TEĎ'), @('2*', 'PŘIŘAZENÍ A NÁVRH'), @('240', 'NASTAVIT JAZYK'))) {
            $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $x[0]; $hg.ColumnDefinitions.Add($cd)
            $t = New-IpText $x[1] 11 'SemiBold' $script:Col.Muted; [Windows.Controls.Grid]::SetColumn($t, $i); if ($i -gt 0 -and $i -lt 3) { $t.Margin = '12,0,0,0' }; [void]$hg.Children.Add($t); $i++
        }
        [void]$tbl.Children.Add($hg)
        if (-not $users.Count) { [void]$tbl.Children.Add((New-IpText 'Na počítači nejsou žádné uživatelské profily.' 13 'Normal' $script:Col.Muted -Margin '14,10,14,10')) }
        foreach ($u in $users) { [void]$tbl.Children.Add((New-IpLangUserRow -U $u -LangOptions $langOpts)) }
        [void]$d.Children.Add((New-IpBorder -Child $tbl -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10 -Padding '0,0,0,4'))
        [void]$d.Children.Add((New-IpText 'Doménový / místní účet se pozná podle SID (místní účty mají SID počítače). Jméno, země a preferovaný jazyk se čtou z Active Directory.' 12 'Normal' $script:Col.Muted -Wrap -Margin '4,6,0,0'))

        # přidat z AD (uživatelé, kteří na PC ještě nebyli)
        if ((Test-IpLangFull) -and $mi -and $mi.PartOfDomain) {
            [void]$d.Children.Add((New-IpText 'Přidat doménového uživatele' 16 'Bold' -Margin '0,20,0,4'))
            [void]$d.Children.Add((New-IpText 'Pro uživatele, který se na tomto PC ještě nepřihlásil. Jazyk se mu nastaví při prvním přihlášení.' 12.5 'Normal' $script:Col.Muted -Wrap -Margin '0,0,0,6'))
            $sr = New-IpPanel 'Horizontal'
            $tb = New-Object Windows.Controls.TextBox; $tb.Width = 320; $tb.Padding = '8,5'; $tb.Text = [string]$L.Query; $tb.BorderBrush = Get-IpBrush $script:Col.Line
            $tb.ToolTip = 'Jméno, příjmení, login nebo e-mail'
            $tb.Add_TextChanged({ param($s, $e) $script:S.L.Query = $s.Text })
            $go = New-IpButton $(if ($L.Searching) { 'Hledám…' } else { 'Hledat v AD' }) 'Btn' $null '8,0,0,0' '12,5'; $go.IsEnabled = -not $L.Searching -and -not $L.Busy
            $go.Add_Click({ Invoke-IpSafe { Start-IpLangFind } })
            $tb.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-IpSafe { $script:S.L.Query = $s.Text; Start-IpLangFind } } })
            [void]$sr.Children.Add($tb); [void]$sr.Children.Add($go); [void]$d.Children.Add($sr)
            if ($L.FindError) { [void]$d.Children.Add((New-IpText $L.FindError 13 'Normal' $script:Col.Err -Wrap -Margin '0,6,0,0')) }
            $known = @{}; foreach ($u in $users) { $known[$u.Sid] = 1 }
            $found = @($L.Found | Where-Object { -not $known.ContainsKey($_.Sid) })
            if ($found.Count) {
                $fl = New-IpPanel
                foreach ($f in $found) {
                    $fg = New-Object Windows.Controls.DockPanel; $fg.Margin = '12,6,12,6'
                    $ab = New-IpButton 'Přidat' 'Btn' $f '' '10,3'; [Windows.Controls.DockPanel]::SetDock($ab, 'Right')
                    $ab.Add_Click({ param($s, $e) Invoke-IpSafe {
                            $u = $s.Tag; $L = $script:S.L; $L.Extra[$u.Sid] = $u
                            $L.Pending[$u.Sid] = if ($u.Suggested) { $u.Suggested.Id } elseif ($L.Data.Languages.Default) { $L.Data.Languages.Default } else { $L.Data.Languages.Items[0].Id }
                            Update-IpLangWindow } })
                    [void]$fg.Children.Add($ab)
                    $info = @($f.Ad.DisplayName, $f.Ad.Department, $f.Ad.City, $(if ($f.Ad.Country) { "země $($f.Ad.Country)" })) | Where-Object { $_ }
                    $ft = New-IpPanel; [void]$ft.Children.Add((New-IpText $f.Name 13.5 'SemiBold')); [void]$ft.Children.Add((New-IpText ($info -join ' · ') 12.5 'Normal' $script:Col.Muted -Wrap))
                    [void]$fg.Children.Add($ft)
                    [void]$fl.Children.Add((New-IpBorder -Child $fg -BorderColor $script:Col.Line2 -Thickness '0,1,0,0'))
                }
                [void]$d.Children.Add((New-IpBorder -Child $fl -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10 -Margin '0,8,0,0'))
            }
            elseif (@($L.Found).Count) { [void]$d.Children.Add((New-IpText 'Nalezení uživatelé už jsou v seznamu nahoře.' 13 'Normal' $script:Col.Muted -Margin '0,6,0,0')) }
        }

        # celý počítač
        if (Test-IpLangFull) {
            [void]$d.Children.Add((New-IpText 'Celý počítač' 16 'Bold' -Margin '0,22,0,6'))
            $mg = New-Object Windows.Controls.Grid
            foreach ($wd in @('330', '*')) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $wd; $mg.ColumnDefinitions.Add($cd) }
            $row = 0
            $addRow = { param($label, $hint, $ctl)
                $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = 'Auto'; $mg.RowDefinitions.Add($rd)
                $tp = New-IpPanel; $tp.Margin = '14,10,12,10'; [void]$tp.Children.Add((New-IpText $label 13.5 'SemiBold' -Wrap)); [void]$tp.Children.Add((New-IpText $hint 12 'Normal' $script:Col.Muted -Wrap))
                [Windows.Controls.Grid]::SetRow($tp, $row); [void]$mg.Children.Add($tp)
                $ctl.Margin = '0,10,14,10'; $ctl.HorizontalAlignment = 'Left'
                [Windows.Controls.Grid]::SetRow($ctl, $row); [Windows.Controls.Grid]::SetColumn($ctl, 1); [void]$mg.Children.Add($ctl)
                Set-Variable -Name row -Value ($row + 1) -Scope 1 }

            $da = if ($data.Assign -and $data.Assign.ContainsKey('default')) { $data.Assign['default'] } else { $null }
            $o = @(, @('__keep', $(if ($da) { "beze změny ($($da.Language))" } else { '— beze změny (nenastaveno) —' }))) + $langOpts
            if ($da) { $o += , @('__none', '✕ zrušit') }
            $sv = if ($L.Pending.ContainsKey('default')) { if ($L.Pending['default']) { [string]$L.Pending['default'] } else { '__none' } } else { '__keep' }
            $cb = New-IpCombo -Options $o -Selected $sv -Tag 'default' -Enabled (-not $L.Busy) -Width 320 -OnChange { param($s, $e) Invoke-IpSafe {
                    $v = [string]$s.SelectedItem.Tag
                    if ($v -eq '__keep') { [void]$script:S.L.Pending.Remove('default') } elseif ($v -eq '__none') { $script:S.L.Pending['default'] = '' } else { $script:S.L.Pending['default'] = $v }
                    Update-IpLangFooter } }
            & $addRow 'Noví uživatelé' 'Jazyk pro každého, kdo se na tomto PC přihlásí poprvé a nemá vlastní přiřazení.' $cb

            $o = @(, @('__keep', "— beze změny (teď $($mi.SystemLocale)) —")) + @($langs.Items | Where-Object SystemLocale | Group-Object SystemLocale | ForEach-Object { , @($_.Name, "$($_.Name)  ·  $($_.Group[0].Name)") })
            $cb = New-IpCombo -Options $o -Selected $(if ($L.MachineSel.SystemLocale) { $L.MachineSel.SystemLocale } else { '__keep' }) -Tag 'SystemLocale' -Enabled (-not $L.Busy) -Width 320 -OnChange { param($s, $e) Invoke-IpSafe {
                    $v = [string]$s.SelectedItem.Tag; $script:S.L.MachineSel['SystemLocale'] = if ($v -eq '__keep') { '' } else { $v }; Update-IpLangFooter } }
            & $addRow 'Jazyk systému pro programy bez Unicode' 'Starší programy (diakritika, kódování souborů). Platí pro celý počítač, projeví se po restartu.' $cb

            $o = @(, @('__keep', "— beze změny (teď $($mi.TimeZone)) —")) + @($langs.Items | Where-Object TimeZone | Group-Object TimeZone | ForEach-Object { , @($_.Name, "$($_.Name)  ·  $(($_.Group | ForEach-Object Id) -join ', ')") })
            $cb = New-IpCombo -Options $o -Selected $(if ($L.MachineSel.TimeZone) { $L.MachineSel.TimeZone } else { '__keep' }) -Tag 'TimeZone' -Enabled (-not $L.Busy) -Width 320 -OnChange { param($s, $e) Invoke-IpSafe {
                    $v = [string]$s.SelectedItem.Tag; $script:S.L.MachineSel['TimeZone'] = if ($v -eq '__keep') { '' } else { $v }; Update-IpLangFooter } }
            & $addRow 'Časové pásmo' 'Platí pro celý počítač, hned.' $cb

            $need = @($L.Pending.Values | Where-Object { $_ } | ForEach-Object { $langs.ById[$_].Ui } | Where-Object { $_ -and @($mi.UiLanguages) -notcontains $_ } | Select-Object -Unique)
            $txt = if ($need.Count) { "Chybí: $($need -join ', ') – při uložení se doinstaluje " + $(if ($mi.CanInstallLanguage) { 'z Windows Update (vyžaduje internet).' } else { "z NAS ($($langs.LanguagePackRoot))." }) + ' Pak je potřeba restart.' } else { 'Všechny vybrané jazyky Windows jsou na PC nainstalované.' }
            $lp = New-IpText $txt 13 'Normal' $(if ($need.Count) { $script:Col.Warn } else { $script:Col.Ok }) -Wrap
            & $addRow 'Jazykové balíčky Windows' "Na PC: $(@($mi.UiLanguages) -join ', ')" $lp
            [void]$d.Children.Add((New-IpBorder -Child $mg -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10))
        }
    }

    # průběh a výsledek
    if ($L.Log.Count -or $L.Done) {
        [void]$d.Children.Add((New-IpText $(if ($L.Busy) { 'Probíhá nastavení' } else { 'Výsledek' }) 16 'Bold' -Margin '0,22,0,6'))
        $rp = New-IpPanel -Margin '14,10,14,10'
        if ($L.Done) {
            foreach ($r in @($L.Done.Results)) {
                $ic = switch ($r.State) { 'ok' { 'ok' } 'later' { 'info' } 'warn' { 'warn' } 'err' { 'err' } default { 'na' } }
                $h = New-IpPanel 'Horizontal' '0,0,0,6'; [void]$h.Children.Add((New-IpStateIcon $ic 20))
                $who = if ($r.Sid -eq 'default') { 'Noví uživatelé' } elseif ($r.Account) { $r.Account } else { 'Váš účet' }
                $lname = if ($r.Language) { Get-IpLangName $r.Language } else { '' }
                [void]$h.Children.Add((New-IpText "$who$(if ($lname) { " – $lname" }): $($r.Message)" 13.5 'Normal' '' -Wrap -Margin '8,1,0,0'))
                [void]$rp.Children.Add($h)
            }
            if ($L.Done.Relogon) { [void]$rp.Children.Add((New-IpText 'Jazyk Windows se změní po odhlášení a novém přihlášení uživatele.' 13 'SemiBold' $script:Col.Warn -Wrap -Margin '0,6,0,0')) }
            if ($L.Done.Reboot) { [void]$rp.Children.Add((New-IpText 'Některé změny se projeví až po restartu počítače.' 13 'SemiBold' $script:Col.Warn -Wrap -Margin '0,4,0,0')) }
        }
        foreach ($x in @($L.Log | Select-Object -Last 40)) {
            $col = switch ($x.Level) { 'Error' { $script:Col.Err } 'Warning' { $script:Col.Warn } 'Success' { $script:Col.Ok } default { $script:Col.Muted } }
            [void]$rp.Children.Add((New-IpText $x.Message 12.5 'Normal' $col -Wrap -Margin '0,2,0,0'))
        }
        [void]$d.Children.Add((New-IpBorder -Child $rp -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '1' -Radius 10))
    }

    # spodní lišta
    $grid = New-Object Windows.Controls.Grid
    foreach ($h in @('*', 'Auto')) { $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = $h; $grid.RowDefinitions.Add($rd) }
    $sv = New-Object Windows.Controls.ScrollViewer; $sv.Content = $d; [void]$grid.Children.Add($sv); $L.Scroll = $sv
    $foot = New-Object Windows.Controls.DockPanel
    $bp = New-IpPanel 'Horizontal'; [Windows.Controls.DockPanel]::SetDock($bp, 'Right')
    $bc = New-IpButton 'Zavřít' 'Btn' $null '0,0,10,0'; $bc.Add_Click({ Invoke-IpSafe { $script:S.L.Win.Close() } })
    $bsv = New-IpButton 'Uložit a nastavit' 'Primary' $null '' '18,8'
    $bsv.Add_Click({ Invoke-IpSafe { Save-IpLanguage } })
    [void]$bp.Children.Add($bc); [void]$bp.Children.Add($bsv); [void]$foot.Children.Add($bp)
    $st = New-IpText '' 13 'Normal' $script:Col.Muted -Wrap; $st.VerticalAlignment = 'Center'; [void]$foot.Children.Add($st)
    $L.SumText = $st; $L.SaveBtn = $bsv
    $fb = New-IpBorder -Child $foot -Bg $script:Col.Surface -BorderColor $script:Col.Line -Thickness '0,1,0,0' -Padding '20,12'
    [Windows.Controls.Grid]::SetRow($fb, 1); [void]$grid.Children.Add($fb)
    $w.Content = $grid
    Update-IpLangFooter
    # Po překreslení zůstat na stejném místě (ne skok nahoru při každém řádku průběhu).
    $L.ScrollTo = $off
    if ($off) { [void]$sv.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action] { if ($script:S.L.Scroll) { $script:S.L.Scroll.ScrollToVerticalOffset($script:S.L.ScrollTo) } }) }
}

function Start-IpLangFind {
    $L = $script:S.L; $q = ([string]$L.Query).Trim()
    if ($L.Searching) { return }
    if (-not $L.Data) { Show-IpToast 'Počkejte, až se načte seznam uživatelů.'; return }
    if ($q.Length -lt 2) { Show-IpToast 'Zadejte aspoň 2 znaky jména nebo loginu.'; return }
    $L.Searching = $true; $L.FindError = ''
    Start-IpJob -Kind 'langfind' -Script $script:LangFindJob -Params @{ Languages = $L.Data.Languages; Query = $q; Queue = $script:S.Queue }
    Update-IpLangWindow
}

#endregion

#region Manuál

function Show-IpManual {
    $w = New-Object Windows.Window
    $w.Title = 'O instalátoru'; $w.Owner = $script:S.Win; $w.WindowStartupLocation = 'CenterOwner'
    $wa = [Windows.SystemParameters]::WorkArea; $w.Width = [Math]::Min(1000, $wa.Width - 80); $w.Height = $wa.Height - 60
    $w.Background = Get-IpBrush $script:Col.Bg; $w.FontFamily = 'Segoe UI'; $w.FontSize = 14
    $w.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Close() } })
    $script:S.ManualWin = $w; $w.Add_Closed({ $script:S.ManualWin = $null }); Set-IpOffscreen $w
    $d = New-IpPanel -Margin '34,26,34,40'; $d.MaxWidth = 860; $d.HorizontalAlignment = 'Left'
    $sec = @(
        @('Jak s aplikací pracovat', @(
                '1 · Úvodní kontrola ověří oprávnění, NAS, internet, instalátor Sophos, písmo Code128, místo na disku a obsah NAS. U každé chyby je postup, co udělat. Pokračovat jde vždy.',
                '2 · Vlevo vyberte balíček. Klik nahradí výběr programy z balíčku, povinný základ zůstává. »Jen povinný základ« začne bez balíčku.',
                '3 · Uprostřed zkontrolujte, co se nainstaluje: verzi (výběr jen když je na NAS víc verzí, doporučená je nejnovější) a pro koho (zelená tečka = doporučení).',
                '4 · Vpravo přidejte nebo odeberte jednotlivé programy. U kategorie jsou tlačítka Vybrat vše a Odebrat vše.',
                '5 · Instalovat vybrané. Instalace běží na pozadí. U programů se štítkem »S OKNEM« dokončete průvodce instalátoru, okno aplikace se mezitím zmenší.',
                '6 · Souhrn ukáže, co se povedlo, co bylo přeskočeno a co vyžaduje pozornost. U chyb je karta s postupem a tlačítky Zkusit znovu / Přeskočit.')),
        @('Kontrolky stavu', @(
                'Zelená = funguje. Oranžová = funguje s problémem (pomalé spojení, starý instalátor…), lze pokračovat. Červená = nefunguje nebo chybí.',
                'Klikněte na kontrolku v horní liště: otevře se okno Stav a návod s aktuálním stavem a postupem krok za krokem.',
                'Stav se kontroluje znovu každou minutu a po každé instalaci.')),
        @('Odkud se instaluje', @(
                'Nejdřív z NAS (offline, bez internetu). Když instalátor na NAS chybí nebo selže a program je ve winget, nainstaluje se z internetu.',
                'Když nefunguje internet, instaluje se jen z NAS. Když nefunguje NAS, jen z internetu.',
                'Aplikace NAS prochází sama: pozná programy podle pravidel v catalog.json, přečte verze z metadat souborů a seřadí je. Nový soubor, přejmenování nebo nová verze se projeví při dalším spuštění bez úprav skriptu.')),
        @('Tichá instalace a okna instalátorů', @(
                'Instalátory se spouštějí bez oken: MSI s /qn, Inno Setup /VERYSILENT, NSIS /S, WiX Burn /quiet, winget --silent. Restart se potlačí a jen doporučí v souhrnu.',
                'Před aktualizací se zavřou běžící programy (uvidíte upozornění). U VPN se předem důvěřuje vydavateli ovladače, aby se Windows neptala.',
                'Když tichý instalátor přesto otevře okno, aplikace to do 25 s zjistí a ukáže kartu s tlačítkem Přepnout do okna. Známá okna odklikne podle pravidla v katalogu.',
                'Programy, které tichou instalaci neumí, se spustí s oknem – musíte je dokončit (případně se v nich přihlásit).')),
        @('Obsah NAS a výjimky', @(
                'Okno Obsah NAS ukazuje rozpoznané programy a verze, vyloučené soubory (odinstalátory, jazykové balíčky, jiné varianty) a nerozpoznané soubory.',
                'Vyloučený nebo nerozpoznaný soubor jde povolit. Aplikace nejdřív ukáže, proč je vyloučený a co hrozí. Povolení platí jen do zavření instalátoru, nic se neukládá a na NAS se nic nemění.')),
        @('Kde jsou logy', @(
                "Log: $($script:S.Settings.LogDirectory). Podrobné logy MSI jsou ve stejné složce. Index NAS: $($script:S.Settings.IndexPath).",
                'Když se aplikace vůbec nespustí, použijte Diagnostika.cmd – vypíše, co chybí.'))
    )
    foreach ($s in $sec) {
        [void]$d.Children.Add((New-IpText $s[0] 19 'Bold' -Margin '0,22,0,8'))
        foreach ($t in $s[1]) { [void]$d.Children.Add((New-IpText $t 14 'Normal' '' -Wrap -Margin '0,0,0,8')) }
    }
    $sv = New-Object Windows.Controls.ScrollViewer; $sv.Content = $d; $w.Content = $sv
    [void]$w.ShowDialog()
}

#endregion

#region Spuštění okna

function Save-IpSnapshot { param($Window, [string] $Name)
    # Vykreslí obsah okna do PNG (i když je okno mimo obrazovku).
    $el = $Window.Content; if (-not $el) { return }
    $w = [int][Math]::Max(1, $el.ActualWidth); $h = [int][Math]::Max(1, $el.ActualHeight)
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($el)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create((Join-Path $env:IP_SNAP_DIR "ip-$Name.png")); try { $enc.Save($fs) } finally { $fs.Dispose() }
}

function Set-IpOffscreen { param($Window)
    # Testovací režim: okno mimo viditelnou plochu, aby nerušilo práci na počítači.
    if (-not $env:IP_SNAP_DIR) { return }
    $Window.WindowState = 'Normal'; $Window.WindowStartupLocation = 'Manual'; $Window.Left = -32000; $Window.Top = -32000
    if ($Window -eq $script:S.Win) { $Window.Width = 1680; $Window.Height = 960 } else { $Window.Width = 1240; $Window.Height = 900 }
    $Window.ShowInTaskbar = $false
}

function Invoke-IpDebugView {
    # Jen pro vývoj: IP_DEBUG=start|main|status|nas|manual otevře po první kontrole danou obrazovku;
    # s IP_SNAP_DIR uloží obsah oken do PNG a aplikaci zavře.
    if ($env:IP_SNAP_DIR) {
        $t = New-Object Windows.Threading.DispatcherTimer; $t.Interval = [TimeSpan]::FromSeconds(3)
        $t.Add_Tick({ param($s, $e) $s.Stop(); Invoke-IpSafe {
                    Save-IpSnapshot $script:S.Win "$($env:IP_DEBUG)-main"
                    foreach ($x in @($script:S.StatusWin, $script:S.NasWin, $script:S.ManualWin, $script:S.L.Win)) { if ($x) { Save-IpSnapshot $x "$($env:IP_DEBUG)-dialog"; $x.Close() } }
                    $script:S.Win.Close() } })
        $t.Start()
    }
    switch ($env:IP_DEBUG) {
        'start' { }
        'main' { Set-IpPage 'main'; Select-IpBundle 'kancelar' }
        'status' { Set-IpPage 'main'; Show-IpStatusWindow -Key 'sophos' }
        'nas' { Show-IpNasWindow }
        'manual' { Show-IpManual }
        'lang' { Show-IpLanguageWindow }
    }
}

function Show-IpApp {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Catalog, [Parameter(Mandatory)] [string] $SrcDir, [switch] $SelfTest, [switch] $UseBroker)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $xaml = [IO.File]::ReadAllText((Join-Path $SrcDir 'MainWindow.xaml'), [Text.Encoding]::UTF8)
    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((New-Object IO.StringReader $xaml)))
    $script:C = @{}
    foreach ($n in 'HdSub', 'TabStart', 'TabMain', 'LedPanel', 'BtnLang', 'BtnNas', 'BtnManual', 'PageStart', 'StartSub', 'CheckList', 'BtnRecheck', 'BtnGo', 'StartMsg', 'PageMain',
        'WhoText', 'BundleList', 'BtnClear', 'MidTitle', 'MidCount', 'ModePanel', 'RbRec', 'RbAll', 'RbUser', 'SelScroll', 'SelList', 'RunPanel', 'SummaryBox', 'SummaryPanel',
        'ProgText', 'Prog', 'ProbList', 'RunList', 'LogBox', 'BtnLog', 'BtnCancel', 'BtnNew', 'BtnInstall', 'SumText', 'TxtSearch', 'SearchHint', 'ChkMissing', 'CmbCat',
        'BusyNote', 'CatScroll', 'CatList', 'Toast', 'ToastText') {
        $script:C[$n] = $win.FindName($n)
        if (-not $script:C[$n]) { throw "V MainWindow.xaml chybí prvek '$n'." }
    }
    $sel = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in $Catalog.Items | Where-Object Required) { [void]$sel.Add($i.Id) }
    $script:S = @{
        Settings = $Settings; Catalog = $Catalog; SrcDir = $SrcDir; Win = $win; Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Jobs = New-Object System.Collections.ArrayList; Health = @(); Index = $null; Installed = @{}; User = $null; Winget = $null
        Sel = $sel; Bundle = $null; Mode = 'rec'; Scope = @{}; Ver = @{}; Cat = 'Všechny kategorie'; Query = ''; Miss = $false; Run = $null
        Allowed = [ordered]@{}; Done = @{}; Checking = $true; ScanMsg = 'Ověřuji NAS, internet a obsah NAS…'; CheckedAt = $null; Page = 'start'
        StatusWin = $null; StatusKey = 'nas'; NasWin = $null; ManualWin = $null; DebugDone = $false; Updating = $false
        UseBroker = [bool]$UseBroker; IsAdmin = (Test-IpAdmin)
        LangAssign = $(try { Read-IpLanguageAssignments -Settings $Settings } catch { @{} }); Langs = $null
        L = @{
            Win = $null; Data = $null; Loading = $false; Error = ''; Busy = $false; Pending = @{}; Extra = [ordered]@{}; Found = @(); Query = ''; Searching = $false; FindError = ''
            Parts = (New-Object 'System.Collections.Generic.HashSet[string]' (, [string[]]@('keyboard', 'ui', 'region'))); MachineSel = @{ SystemLocale = ''; TimeZone = '' }
            Log = New-Object System.Collections.ArrayList; Done = $null; SelfSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Scroll = $null; ScrollTo = 0; SumText = $null; SaveBtn = $null; Del = (New-Object 'System.Collections.Generic.HashSet[string]'); ThenSave = $false; PrevDone = $null
        }
    }
    $script:C.HdSub.Text = "$([Environment]::MachineName) · v3"

    $win.Dispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true; Write-IpUiError $e.Exception })
    $script:C.TabStart.Add_Click({ Invoke-IpSafe { Set-IpPage 'start' } })
    $script:C.TabMain.Add_Click({ Invoke-IpSafe { Set-IpPage 'main' } })
    $script:C.BtnGo.Add_Click({ Invoke-IpSafe { Set-IpPage 'main' } })
    $script:C.BtnRecheck.Add_Click({ Invoke-IpSafe { Start-IpHealthCheck -Rescan $true } })
    $script:C.BtnLang.Add_Click({ Invoke-IpSafe { Show-IpLanguageWindow } })
    $script:C.BtnNas.Add_Click({ Invoke-IpSafe { Show-IpNasWindow } })
    $script:C.BtnManual.Add_Click({ Invoke-IpSafe { Show-IpManual } })
    $script:C.BtnClear.Add_Click({ Invoke-IpSafe { Clear-IpSelection } })
    $script:C.BtnInstall.Add_Click({ Invoke-IpSafe { Start-IpInstall } })
    $script:C.BtnCancel.Add_Click({ Invoke-IpSafe { $script:S.Run.State['Cancel'] = $true; Show-IpToast 'Instalace se zastaví po dokončení aktuální položky.' } })
    $script:C.BtnNew.Add_Click({ Invoke-IpSafe { $script:S.Run = $null; Update-IpAll } })
    $script:C.BtnLog.Add_Click({ Invoke-IpSafe { $f = Get-IpLogFile; if ($f -and (Test-Path $f)) { Start-Process notepad.exe -ArgumentList "`"$f`"" } } })
    foreach ($rb in 'RbRec', 'RbAll', 'RbUser') { $script:C[$rb].Add_Checked({ param($s, $e) Invoke-IpSafe { $script:S.Mode = @{ RbRec = 'rec'; RbAll = 'all'; RbUser = 'user' }[$s.Name]; $script:S.Scope = @{}; if ($script:S.Health) { Update-IpMiddle } } }) }
    $script:C.TxtSearch.Add_TextChanged({ param($s, $e) Invoke-IpSafe { $script:S.Query = $s.Text; $script:C.SearchHint.Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' }; Update-IpCatalog } })
    $script:C.ChkMissing.Add_Click({ param($s, $e) Invoke-IpSafe { $script:S.Miss = [bool]$s.IsChecked; Update-IpCatalog } })
    $script:C.CmbCat.Add_SelectionChanged({ param($s, $e) Invoke-IpSafe { if (-not $script:S.Updating -and $s.SelectedItem) { $script:S.Cat = [string]$s.SelectedItem; Update-IpCatalog } } })
    $win.Add_Closing({ param($s, $e)
            if (Test-IpBusy) {
                $a = [Windows.MessageBox]::Show('Instalace stále běží. Opravdu zavřít? Právě instalovaný program se dokončí na pozadí, další se už nespustí.', 'Instalace programů', 'YesNo', 'Warning')
                if ($a -ne 'Yes') { $e.Cancel = $true } else { $script:S.Run.State['Cancel'] = $true }
            } })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({ Invoke-IpSafe { Invoke-IpPump } })
    $timer.Start()
    $pulse = New-Object Windows.Threading.DispatcherTimer
    $pulse.Interval = [TimeSpan]::FromSeconds(60)
    $pulse.Add_Tick({ Invoke-IpSafe { if (-not (Test-IpBusy) -and -not $script:S.Checking) { Start-IpHealthCheck -Rescan $false } } })
    $pulse.Start()

    Write-IpLog -Settings $Settings -Message "=== Start Instalace programů v3 na $([Environment]::MachineName) jako $([Environment]::UserDomainName)\$([Environment]::UserName) ==="
    Update-IpAll
    Start-IpHealthCheck -Rescan $true
    if ($SelfTest) {
        # Test bez zobrazení: dokončí kontrolu na pozadí, vykreslí všechny části a zavře se.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($script:S.Checking -and $sw.Elapsed.TotalSeconds -lt 180) {
            $win.Dispatcher.Invoke([Action] { Invoke-IpPump }, 'Background'); Start-Sleep -Milliseconds 200
        }
        Set-IpPage 'main'; Select-IpBundle 'kancelar'; Update-IpAll
        $script:S.StatusKey = 'nas'
        $timer.Stop(); $pulse.Stop()
        return [pscustomobject]@{ Health = $script:S.Health; Selected = @(Get-IpSelected | ForEach-Object Id); Rows = $script:C.SelList.Children.Count; Catalog = $script:C.CatList.Children.Count; Notes = (Get-IpNotes) }
    }
    Set-IpOffscreen $win
    [void]$win.ShowDialog()
    $timer.Stop(); $pulse.Stop()
}

#endregion

Export-ModuleMember -Function 'Show-IpApp'
