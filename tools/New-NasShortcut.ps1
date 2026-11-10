# Vytvoří ve složce instalátoru zástupce »Instalace programů.lnk« s ikonou, který jde přetáhnout na plochu.
# Cíl i ikona míří na síťovou cestu, takže zástupce funguje na každém PC s přístupem k NAS.
# Spusťte po nakopírování složky na NAS:  powershell -ExecutionPolicy Bypass -File tools\New-NasShortcut.ps1
param([string] $DeployPath = '\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3')
$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $DeployPath 'Instalace programů.lnk'))
$lnk.TargetPath = Join-Path $DeployPath 'Instalace-programu.cmd'
$lnk.IconLocation = (Join-Path $DeployPath 'Instalace-programu.ico') + ',0'
$lnk.WindowStyle = 7
$lnk.Description = 'Nainstaluje programy z firemního NAS'
$lnk.Save()
"Vytvořeno: $(Join-Path $DeployPath 'Instalace programů.lnk')"
