#Requires -Version 5.1
<#
.SYNOPSIS
    Nastaví přihlášenému uživateli jazyk podle přiřazení z okna Jazyk uživatelů.
.DESCRIPTION
    Běží POD UŽIVATELEM (bez práv správce):
      - při každém přihlášení (úloha InstalaceProgramu-Jazyk, skupina Uživatelé),
      - hned po uložení v okně, když je uživatel zrovna přihlášený.
    Přiřazení čte z %ProgramData%\InstalaceProgramu\Language\assignments.json (zapisuje jen správce/SYSTEM).
    Každé přiřazení se použije jen jednou (razítko Stamp v HKCU) – uživatel si pak může jazyk změnit sám.
    Přiřazení "default" platí pro uživatele, kterým aplikace jazyk ještě nikdy nenastavovala (noví uživatelé).

    Nastavuje podle částí (Parts): keyboard = jazyky a klávesnice, ui = jazyk Windows,
    region = formáty (datum, čísla, měna) a domovská oblast.
.NOTES
    Návratové kódy: 0 = nastaveno / nic k nastavení, 10 = nastaveno, ale jazyk Windows chybí (balíček),
    1 = chyba. Jazyk Windows se projeví po odhlášení.
#>
param([string] $AssignmentsPath = (Join-Path $env:ProgramData 'InstalaceProgramu\Language\assignments.json'), [switch] $Force)
$ErrorActionPreference = 'Stop'
$markerKey = 'HKCU:\Software\InstalaceProgramu\Language'
$logDir = Join-Path $env:LOCALAPPDATA 'InstalaceProgramu\Logs'
function Write-Log([string] $m) {
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $logDir 'jazyk.log') -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m) -Encoding UTF8
    } catch { }
}

try {
    if (-not (Test-Path -LiteralPath $AssignmentsPath)) { exit 0 }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $all = [IO.File]::ReadAllText($AssignmentsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $marker = Get-ItemProperty -Path $markerKey -ErrorAction SilentlyContinue
    $a = $all.Users.PSObject.Properties[$sid]
    $a = if ($a) { $a.Value } elseif (-not $marker -and $all.Users.PSObject.Properties['default']) { $all.Users.default } else { $null }
    if (-not $a) { exit 0 }
    $parts = @($a.Parts)
    if (-not $Force -and $marker -and $marker.Stamp -eq $a.Stamp) {
        # Už použito. Výjimka: jazyk Windows tehdy chyběl (balíček se stahoval) a teď už je – doplnit jen ten.
        $uiNow = Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\$($a.Ui)"
        if ($marker.Result -eq 'ui-missing' -and $parts -contains 'ui' -and $uiNow) { $parts = @('ui') } else { exit 0 }
    }

    Write-Log "Nastavuji jazyk $($a.Language) (části: $($parts -join ', '))"
    $uiMissing = $false

    if ($parts -contains 'keyboard') {
        # Seznam jazyků: hlavní jazyk se svými klávesnicemi + doplňkové (např. angličtina).
        $list = New-WinUserLanguageList $a.Culture
        if (@($a.Keyboards).Count) { $list[0].InputMethodTips.Clear(); foreach ($t in $a.Keyboards) { $list[0].InputMethodTips.Add($t) } }
        foreach ($s in @($a.Secondary)) {
            if (-not $s.Culture -or $s.Culture -eq $a.Culture) { continue }
            $x = New-WinUserLanguageList $s.Culture
            if (@($s.Keyboards).Count) { $x[0].InputMethodTips.Clear(); foreach ($t in $s.Keyboards) { $x[0].InputMethodTips.Add($t) } }
            $list.Add($x[0])
        }
        Set-WinUserLanguageList -LanguageList $list -Force
        if (@($a.Keyboards).Count) { Set-WinDefaultInputMethodOverride -InputTip $a.Keyboards[0] }
    }
    if ($parts -contains 'ui') {
        $installed = Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\$($a.Ui)"
        if ($installed) { Set-WinUILanguageOverride -Language $a.Ui }
        else { $uiMissing = $true; Write-Log "Jazyk Windows $($a.Ui) není na počítači nainstalovaný – nastaví ho IT doinstalováním jazykového balíčku." }
    }
    if ($parts -contains 'region') {
        Set-Culture -CultureInfo $a.Culture
        if ($a.GeoId) { Set-WinHomeLocation -GeoId ([int]$a.GeoId) }
    }

    if (-not (Test-Path -LiteralPath $markerKey)) { New-Item -Path $markerKey -Force | Out-Null }
    Set-ItemProperty -Path $markerKey -Name Stamp -Value ([string]$a.Stamp)
    Set-ItemProperty -Path $markerKey -Name Language -Value ([string]$a.Language)
    Set-ItemProperty -Path $markerKey -Name AppliedAt -Value ((Get-Date).ToString('s'))
    Set-ItemProperty -Path $markerKey -Name Result -Value $(if ($uiMissing) { 'ui-missing' } else { 'ok' })
    Write-Log 'Hotovo.'
    if ($uiMissing) { exit 10 }
    exit 0
}
catch {
    Write-Log "Chyba: $($_.Exception.Message)"
    exit 1
}
