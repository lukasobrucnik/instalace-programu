#Requires -Version 5.1
<#
.SYNOPSIS
    Nasadí na PC instalaci programů BEZ PRÁV SPRÁVCE (bez dotazu UAC pro uživatele).
.DESCRIPTION
    Spouští se jako SYSTEM – nejlépe GPO, spouštěcí skript počítače (viz README). Na PC:
      1. zkopíruje aplikaci z NAS do C:\Program Files\InstalaceProgramu (zapisovat smí jen SYSTEM/správci),
      2. zaregistruje úlohu InstalaceProgramu-Broker (běží jako SYSTEM; přihlášení uživatelé ji
         smí jen spustit, ne změnit),
      3. připraví složku pro požadavky z okna a dá zástupce na veřejnou plochu.
    Opakované spuštění vše jen aktualizuje. Nic se nemaže, kromě -Uninstall.
.PARAMETER Uninstall
    Odebere úlohu, místní kopii a zástupce.
#>
param([switch] $Uninstall)
$ErrorActionPreference = 'Stop'
$srcRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $srcRoot 'src\Common.psm1')
Import-Module (Join-Path $srcRoot 'src\Broker.psm1')
$settings = Get-IpSettings -Path (Join-Path $srcRoot 'config\settings.json')
if (-not (Test-IpAdmin)) { Write-Error 'Spusťte jako SYSTEM (GPO) nebo jako správce.'; exit 2 }
$app = $settings.AppDirectory
$lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Instalace programů.lnk'

try {
    if ($Uninstall) {
        try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteTask($settings.BrokerTaskName, 0) } catch { }
        try { $svc.GetFolder('\').DeleteTask('InstalaceProgramu-Jazyk', 0) } catch { }
        if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
        Remove-Item -LiteralPath (Get-IpBrokerPaths $settings).Requests -Recurse -Force -ErrorAction SilentlyContinue
        Write-IpLog -Settings $settings -Message 'Systémová úloha a místní kopie odebrány.'
        exit 0
    }

    # 1. místní kopie (z NAS spuštěno -> zdroj je NAS; spuštěno z místní kopie -> nic nekopírovat)
    [void](Initialize-IpSecureDirectory -Path $app)
    if ($srcRoot.TrimEnd('\') -ne $app.TrimEnd('\')) {
        & robocopy.exe $srcRoot $app /MIR /R:2 /W:2 /NP /NFL /NDL /NJH /NJS /XF '*.lnk' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Kopírování z $srcRoot do $app selhalo (robocopy $LASTEXITCODE)." }
    }

    # 2. úloha + složky
    Register-IpBroker -Settings $settings -StartScript (Join-Path $app 'tools\Start-Broker.ps1')
    # 2b. úloha při přihlášení pro jazyk uživatelů (okno Jazyk uživatelů)
    try { Import-Module (Join-Path $app 'src\Language.psm1'); Install-IpLanguageAgent -Settings $settings }
    catch { Write-IpLog -Settings $settings -Level Warning -Message "Úlohu pro jazyk uživatelů nejde nasadit: $($_.Exception.Message)" }

    # 3. zástupce na veřejné ploše -> místní spouštěč (funguje i když NAS zrovna neodpovídá)
    try {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = Join-Path $app 'Instalace-programu.cmd'
        $s.IconLocation = (Join-Path $app 'Instalace-programu.ico') + ',0'
        $s.WindowStyle = 7
        $s.Description = 'Nainstaluje programy z firemního NAS'
        $s.Save()
    }
    catch { Write-IpLog -Settings $settings -Level Warning -Message "Zástupce na ploše nejde vytvořit: $($_.Exception.Message)" }

    Write-IpLog -Settings $settings -Level Success -Message "Systémová úloha $($settings.BrokerTaskName) nasazena ($app)."
    exit 0
}
catch {
    try { Write-IpLog -Settings $settings -Level Error -Message "Nasazení systémové úlohy selhalo: $($_.Exception.Message)" } catch { }
    Write-Error $_.Exception.Message
    exit 1
}
