# Uloží .ps1/.psm1 v UTF-8 s BOM – bez BOM čte Windows PowerShell 5.1 češtinu jako ANSI.
param([string] $Root = (Split-Path -Parent $PSScriptRoot))
$bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -LiteralPath $Root -Recurse -Include *.ps1, *.psm1, *.psd1 -File | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    [IO.File]::WriteAllText($_.FullName, $text, $bom)
    "BOM: $($_.Name)"
}
