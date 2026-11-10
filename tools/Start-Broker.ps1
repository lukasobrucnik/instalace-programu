#Requires -Version 5.1
<#
.SYNOPSIS
    Spouští systémová úloha InstalaceProgramu-Broker (SYSTEM), nikdo jiný.
.DESCRIPTION
    1. Je-li NAS dostupný, obnoví místní kopii aplikace (C:\Program Files\InstalaceProgramu) z NAS,
       aby úloha měla stejný katalog jako okno.
    2. Zpracuje čekající požadavky z okna (InstalaceProgramu.ps1 -Broker).
#>
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$code = 2
try {
    Import-Module (Join-Path $app 'src\Common.psm1')
    Import-Module (Join-Path $app 'src\Health.psm1')
    $settings = Get-IpSettings -Path (Join-Path $app 'config\settings.json')
    $deploy = $settings.DeployPath
    if ($deploy -and $deploy -ne $app) {
        $probe = [pscustomobject]@{ SourceRoots = @($deploy); NasProbeSeconds = $settings.NasProbeSeconds }
        if ((Test-IpNas -Settings $probe).Ok -and (Test-Path -LiteralPath (Join-Path $deploy 'InstalaceProgramu.ps1'))) {
            & robocopy.exe $deploy $app /MIR /R:1 /W:1 /NP /NFL /NDL /NJH /NJS /XF '*.lnk' | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-IpLog -Settings $settings -Level Warning -Message "Obnova místní kopie z NAS selhala (robocopy $LASTEXITCODE), pokračuji se stávající." }
        }
    }
}
catch { try { Write-IpLog -Settings $settings -Level Warning -Message "Start úlohy: $($_.Exception.Message)" } catch { } }

& (Join-Path $app 'InstalaceProgramu.ps1') -Broker
$code = $LASTEXITCODE
exit $code
