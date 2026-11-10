# Ladění: ukáže, odkud by se programy instalovaly (bez instalace).
param([string[]] $Ids = @('7zip', 'font-code128', 'teamviewer', 'teams'))
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Common', 'NasIndex', 'Health', 'Install') { Import-Module (Join-Path $root "src\$m.psm1") }
$c = Read-IpCatalog (Join-Path $root 'config\catalog.json'); $s = Get-IpSettings (Join-Path $root 'config\settings.json')
$i = Invoke-IpNasScan -Settings $s -Catalog $c 2>$null
$ctx = @{ NasOk = $true; NetOk = $true; Winget = 'winget.exe'; User = $null }
foreach ($id in $Ids) {
    $it = $c.ById[$id]; $k = @(Get-IpCandidates -Index $i -ItemId $id)
    "{0}: kandidátů {1}, zdroje {2}" -f $id, $k.Count, ($it.Sources -join ',')
    $p = Resolve-IpPlanEntry -Item $it -Index $i -Ctx $ctx
    "   ok={0} zdroj={1} verze={2} důvod={3}" -f $p.Ok, $p.Source, $p.Version, $p.Reason
}
