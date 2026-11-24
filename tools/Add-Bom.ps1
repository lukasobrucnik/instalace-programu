# Uloží .ps1/.psm1/.psd1 v UTF-8 s BOM – bez BOM čte Windows PowerShell 5.1 češtinu jako ANSI.
# Přípona se kontroluje přímo (ne -Include): ve Windows PowerShell 5.1 -Include s -LiteralPath
# nefiltruje spolehlivě – dřívější verze tak poškodila ikonu .ico a přidala BOM do .cmd.
# Soubory .cmd musí zůstat BEZ BOM (jinak cmd nepozná první řádek @echo off).
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
$bom = New-Object System.Text.UTF8Encoding($true)
$ext = @('.ps1', '.psm1', '.psd1')
Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $ext -contains $_.Extension.ToLowerInvariant() } | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    [IO.File]::WriteAllText($_.FullName, $text, $bom)
    "BOM: $($_.Name)"
}
# .cmd: BOM odstranit, konce řádků CRLF
Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -ieq '.cmd' } | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $text = [Text.Encoding]::ASCII.GetString($bytes, $start, $bytes.Length - $start)
    $fixed = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
    if ($start -or $fixed -ne $text) { [IO.File]::WriteAllText($_.FullName, $fixed, [Text.Encoding]::ASCII); "CMD (bez BOM, CRLF): $($_.Name)" }
}
