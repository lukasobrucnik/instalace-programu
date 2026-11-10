#Requires -Version 5.1
<#
.SYNOPSIS
    Úvodní a průběžná kontrola stavu: oprávnění, NAS, internet + winget, Sophos, písmo, disk, index.
    Ke každému stavu vrací srozumitelný popis a postup řešení krok za krokem.
.NOTES
    Stav: 'ok' (zelená), 'warn' (oranžová – funguje s problémem), 'err' (červená – nefunguje).
#>

Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'NasIndex.psm1')

$script:Recheck = @('Klikněte na »Zkontrolovat znovu«', 'Aplikace stav ověří hned. Když je vše v pořádku, kontrolka se zezelená.')

function Find-IpWinget {
    <#
    .SYNOPSIS
        Najde winget.exe. Pod účtem správce (jiným než přihlášený uživatel) často není na PATH,
        proto se hledá i přímo v balíčku App Installer.
    #>
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $dirs = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue)
    $best = $dirs | Sort-Object { [version](($_.Name -split '_')[1]) } -Descending | Where-Object { Test-Path (Join-Path $_.FullName 'winget.exe') } | Select-Object -First 1
    if ($best) { return (Join-Path $best.FullName 'winget.exe') }
    return $null
}

function Test-IpNas {
    <#
    .SYNOPSIS
        Ověří dostupnost NAS s časovým limitem. Nedostupná síťová cesta jinak blokuje až desítky sekund.
    #>
    param([Parameter(Mandatory)] $Settings)
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($roots)
            foreach ($r in $roots) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                if (Test-Path -LiteralPath $r) {
                    $t1 = $sw.ElapsedMilliseconds
                    $null = Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue | Select-Object -First 5
                    return [pscustomobject]@{ Ok = $true; Root = $r; Ms = [int][Math]::Max($t1, $sw.ElapsedMilliseconds - $t1); TimedOut = $false }
                }
            }
            return [pscustomobject]@{ Ok = $false; Root = ($roots -join ', '); Ms = -1; TimedOut = $false }
        }).AddArgument([string[]]$Settings.SourceRoots)
    $h = $ps.BeginInvoke()
    if ($h.AsyncWaitHandle.WaitOne($Settings.NasProbeSeconds * 1000)) {
        $r = @($ps.EndInvoke($h)); $ps.Dispose()
        if ($r.Count) { return $r[0] }
    }
    # Kontrola visí na síťovém timeoutu – necháme ji doběhnout na pozadí a hlásíme nedostupnost.
    return [pscustomobject]@{ Ok = $false; Root = ($Settings.SourceRoots -join ', '); Ms = -1; TimedOut = $true }
}

function Test-IpInternet {
    param([Parameter(Mandatory)] $Settings)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $proxy = [Net.WebRequest]::DefaultWebProxy
        if ($proxy) { $proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
        $req = [Net.WebRequest]::Create($Settings.InternetProbeUrl)
        $req.Method = 'HEAD'; $req.Timeout = $Settings.InternetProbeSeconds * 1000
        $resp = $req.GetResponse(); $resp.Close()
        return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds; Error = '' }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        return [pscustomobject]@{ Ok = $false; Ms = [int]$sw.ElapsedMilliseconds; Error = $msg }
    }
}

function New-IpCheck {
    param([string] $Key, [string] $Label, [string] $Long, [string] $State, [string] $Word, [string] $Title, [string] $Detail, [object[]] $Steps = @(), [string] $How, [bool] $Blocking = $false)
    return [pscustomobject]@{ Key = $Key; Label = $Label; Long = $Long; State = $State; Word = $Word; Title = $Title; Detail = $Detail; Steps = @($Steps); How = $How; Blocking = $Blocking }
}

function Get-IpHealth {
    <#
    .SYNOPSIS
        Sestaví všechny kontroly. NAS a internet se testují tady, pokud nejsou předané.
    #>
    param(
        [Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] $Catalog, [AllowNull()] $Index,
        [AllowNull()] $Nas, [AllowNull()] $Net, [AllowNull()] $User, [AllowNull()] [string] $WingetPath,
        [bool] $Broker
    )
    if (-not $Nas) { $Nas = Test-IpNas -Settings $Settings }
    if (-not $Net) { $Net = Test-IpInternet -Settings $Settings }
    $nasRoot = ($Settings.SourceRoots | Select-Object -First 1)
    $checks = New-Object System.Collections.Generic.List[object]

    # --- oprávnění + přihlášený uživatel
    $admin = Test-IpAdmin
    $me = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
    if (-not $admin -and $Broker) {
        $checks.Add((New-IpCheck 'admin' 'Oprávnění' 'Oprávnění správce' 'ok' 'systémová úloha' 'Instaluje systémová úloha – heslo správce není potřeba' "Spuštěno jako $me bez práv správce. Programy nainstaluje systémová úloha počítače (nastavená IT). Programy s průvodcem a ruční výjimky z NAS takto nainstalovat nejde – ty nainstaluje IT." @() 'Úloha InstalaceProgramu-Broker v Plánovači úloh (spouští se jako SYSTEM).'))
    }
    elseif (-not $admin) {
        $checks.Add((New-IpCheck 'admin' 'Oprávnění' 'Oprávnění správce' 'err' 'chybí' 'Aplikace neběží s oprávněním správce' "Spuštěno jako $me bez práv správce. Instalace se nespustí." @(
                    @('Zavřete aplikaci', 'Okno zavřete křížkem.'),
                    @('Spusťte ji znovu zástupcem »Instalace programů«', 'Na dotaz Windows »Chcete této aplikaci povolit provádět změny?« klikněte Ano a zadejte účet správce.')
                ) 'Token procesu aplikace (role Administrators).' $true))
    }
    elseif (-not $User) {
        $checks.Add((New-IpCheck 'admin' 'Oprávnění' 'Oprávnění správce' 'warn' 'nikdo přihlášen' 'Nikdo není přihlášený u počítače' "Spuštěno jako $me. U konzole není přihlášený žádný uživatel, instalace »jen pro uživatele« proto nejsou k dispozici." @(
                    @('Přihlaste uživatele, pro kterého instalujete', 'Instalace pro všechny uživatele fungují i bez něj.'), $script:Recheck
                ) 'Vlastník procesu explorer.exe v relaci konzole.'))
    }
    else {
        $same = $User.Name -eq $me
        $d = if ($same) { "Spuštěno jako $me (přihlášený uživatel má práva správce)." } else { "Spuštěno jako $me, přihlášený je $($User.Name). Instalace »jen pro uživatele« poběží v relaci $($User.Short), ne pod účtem správce." }
        $checks.Add((New-IpCheck 'admin' 'Oprávnění' 'Oprávnění správce' 'ok' 'v pořádku' 'Aplikace běží s oprávněním správce' $d @() 'Token procesu aplikace; přihlášený uživatel = vlastník explorer.exe.'))
    }

    # --- NAS
    $nasHow = "Test-Path na $nasRoot na pozadí s limitem $($Settings.NasProbeSeconds) s; měří se odezva výpisu složky."
    if ($Nas.Ok -and $Nas.Ms -le $Settings.NasSlowMs) {
        $checks.Add((New-IpCheck 'nas' 'NAS' 'Síťová cesta NAS' 'ok' 'funguje' 'NAS je připojený' "Sdílená složka $($Nas.Root) odpovídá za $($Nas.Ms) ms. Instalace z NAS jedou naplno." @() $nasHow $true))
    }
    elseif ($Nas.Ok) {
        $checks.Add((New-IpCheck 'nas' 'NAS' 'Síťová cesta NAS' 'warn' 'pomalý' 'NAS odpovídá pomalu' "Sdílená složka je dostupná, ale odezva je $($Nas.Ms) ms. Instalace z NAS půjdou, jen pomaleji – velké balíčky mohou trvat několikanásobně déle." @(
                    @('Zjistěte, jak je počítač připojený', 'Ikona sítě vpravo dole na hlavním panelu: vějíř = Wi-Fi, monitor = kabel. Mimo kancelář běží i VPN (FortiClient).'),
                    @('Připojte síťový kabel', 'Na Wi-Fi bývá kopírování z NAS 5–10× pomalejší. Zapojte kabel do zásuvky ve zdi nebo do dokovací stanice.'),
                    @('Na VPN ověřte linku', 'Přes hotspot telefonu nebo slabou domácí linku může instalace z NAS trvat desítky minut. Pokud to jde, instalujte v kanceláři.'),
                    @('Nebo pokračujte', 'Aplikace u každé položky hlídá časový limit. Když NAS nestihne, použije internet (winget), pokud tam program je.'), $script:Recheck
                ) $nasHow $true))
    }
    else {
        $why = if ($Nas.TimedOut) { "neodpověděl do $($Settings.NasProbeSeconds) s" } else { 'neodpovídá' }
        $checks.Add((New-IpCheck 'nas' 'NAS' 'Síťová cesta NAS' 'err' 'odpojeno' 'NAS není připojený' "$nasRoot $why. Programy, které jsou i ve winget, se nainstalují z internetu. Programy jen z NAS, Sophos a písmo teď nepůjdou." @(
                    @('Zkontrolujte připojení k síti', 'Ikona sítě vpravo dole. Když hlásí »Nepřipojeno«, zapojte kabel nebo se připojte k firemní Wi-Fi.'),
                    @('Mimo kancelář připojte VPN', 'Spusťte FortiClient VPN a přihlaste se. Bez VPN NAS z domova ani z jiné pobočky nevidíte.'),
                    @('Ověřte přístup ke sdílené složce', "Stiskněte Win+R, napište \\FS01\backup a Enter. Když se složka otevře, síť funguje. Když chce heslo nebo hlásí »Přístup odepřen«, účet nemá práva – kontaktujte IT."),
                    @('Disk P: nehledejte', 'Aplikace používá síťovou cestu \\FS01\…. Pod účtem správce mapovaný disk P: vidět není, to je v pořádku.'), $script:Recheck
                ) $nasHow $true))
    }

    # --- internet + winget
    $netHow = "HTTPS dotaz na zdroj winget ($($Settings.InternetProbeUrl)) a hledání winget.exe."
    if ($Net.Ok -and $WingetPath -and $Net.Ms -le $Settings.InternetSlowMs) {
        $checks.Add((New-IpCheck 'inet' 'Internet' 'Připojení k internetu' 'ok' 'funguje' 'Internet je připojený' "Připojení funguje ($($Net.Ms) ms) a winget je dostupný – jako záloha pro instalace z NAS i pro programy jen z internetu." @() $netHow))
    }
    elseif ($Net.Ok -and -not $WingetPath) {
        $checks.Add((New-IpCheck 'inet' 'Internet' 'Připojení k internetu' 'warn' 'chybí winget' 'Internet funguje, ale chybí winget' 'Bez nástroje winget se programy z internetu nenainstalují. Programy z NAS fungují normálně.' @(
                    @('Otevřete Microsoft Store', 'Vyhledejte »App Installer« (Instalační služba aplikací) a klikněte Aktualizovat nebo Získat.'),
                    @('Na počítači bez Storu', 'IT nainstaluje balíček Microsoft.DesktopAppInstaller ručně.'), $script:Recheck
                ) $netHow))
    }
    elseif ($Net.Ok) {
        $checks.Add((New-IpCheck 'inet' 'Internet' 'Připojení k internetu' 'warn' 'pomalý' 'Internet je pomalý nebo omezený' "Odezva $($Net.Ms) ms. Programy z internetu půjdou, jen déle." @(
                    @('Připojte se ke kancelářské síti', 'Kabel nebo firemní Wi-Fi. Hotspot telefonu stačí jen na menší programy.'),
                    @('Vypněte měřené připojení', 'Nastavení → Síť a internet → Wi-Fi nebo Ethernet → vlastnosti sítě → Měřené připojení: Vypnuto. Jinak Windows stahování omezuje.'),
                    @('Nebo pokračujte', 'Programy z NAS internet nepotřebují. Z internetu se stahují jen programy, které na NAS nejsou.'), $script:Recheck
                ) $netHow))
    }
    else {
        $checks.Add((New-IpCheck 'inet' 'Internet' 'Připojení k internetu' 'err' 'odpojeno' 'Internet není připojený' "Programy jen z internetu nejdou vybrat. Vše, co je na NAS, se nainstaluje normálně. (Chyba: $($Net.Error))" @(
                    @('Otevřete web v prohlížeči', 'Zkuste třeba www.seznam.cz. Když se objeví přihlašovací stránka (hotel, hostovská Wi-Fi), přihlaste se.'),
                    @('Zkontrolujte proxy', 'Nastavení → Síť a internet → Proxy. Musí být nastavená stejně jako na ostatních firemních počítačích.'),
                    @('Web funguje, ale tady ne?', 'Firewall pravděpodobně blokuje adresy winget (cdn.winget.microsoft.com). Kontaktujte IT.'),
                    @('Nebo pokračujte bez internetu', 'Vše z NAS se nainstaluje. Programy jen z internetu doinstalujete později.'), $script:Recheck
                ) $netHow))
    }

    $nasDownSteps = @(@('Vyřešte nejdřív připojení k NAS', 'Otevřete vlevo položku NAS a postupujte podle jejího návodu.'), $script:Recheck)
    $haveIndex = $Index -and $Index.Items

    # --- Sophos
    $sHow = "Hledá SophosSetup*.exe ve složce SophosInstall; ověří podpis Sophos Ltd a stáří (varování nad $($Settings.SophosMaxAgeDays) dní)."
    $sc = if ($haveIndex) { @(Get-IpCandidates -Index $Index -ItemId 'sophos') | Where-Object Recommended | Select-Object -First 1 } else { $null }
    if (-not $Nas.Ok) {
        $checks.Add((New-IpCheck 'sophos' 'Sophos' 'Instalátor Sophos' 'err' 'neověřeno' 'Nelze ověřit – NAS je odpojený' 'Instalátor Sophosu je jen na NAS, a ten teď neodpovídá.' $nasDownSteps $sHow $true))
    }
    elseif (-not $sc) {
        $checks.Add((New-IpCheck 'sophos' 'Sophos' 'Instalátor Sophos' 'err' 'chybí' 'Instalátor Sophos chybí' 'Ve složce SophosInstall na NAS není instalátor. Sophos je povinný a bez instalátoru se nenainstaluje.' @(
                    @('Přihlaste se do Sophos Central', 'central.sophos.com účtem IT.'),
                    @('Stáhněte instalátor', 'Zařízení → Instalátory → Endpoint Protection → Windows.'),
                    @('Uložte ho na NAS', "Jako SophosSetup_new.exe do $nasRoot\SophosInstall. Soubory se »zap«, »server« nebo »uninstall« v názvu aplikace ignoruje."), $script:Recheck
                ) $sHow $true))
    }
    else {
        $age = [int]((Get-Date) - $sc.Modified).TotalDays
        $sig = $null; try { $sig = Get-AuthenticodeSignature -LiteralPath $sc.Path -ErrorAction Stop } catch { }
        $signer = if ($sig -and $sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        if ($sig -and ($sig.Status -eq 'HashMismatch' -or $sig.Status -eq 'NotSigned' -or ($signer -and $signer -notmatch 'Sophos'))) {
            $checks.Add((New-IpCheck 'sophos' 'Sophos' 'Instalátor Sophos' 'err' 'neplatný' 'Instalátor Sophos má neplatný podpis' "Soubor $($sc.Rel) není podepsaný firmou Sophos nebo je poškozený (stav podpisu: $($sig.Status)). Z bezpečnostních důvodů se nespustí." @(
                        @('Stáhněte instalátor znovu ze Sophos Central', 'Zařízení → Instalátory → Endpoint Protection → Windows.'),
                        @('Nahraďte soubor na NAS', "Uložte ho jako SophosSetup_new.exe do $nasRoot\SophosInstall."), $script:Recheck
                    ) $sHow $true))
        }
        elseif ($age -gt $Settings.SophosMaxAgeDays) {
            $checks.Add((New-IpCheck 'sophos' 'Sophos' 'Instalátor Sophos' 'warn' 'starý' 'Instalátor Sophos je starý' "$($sc.Rel) je $age dní starý. Nainstaluje se a hned se sám aktualizuje, první aktualizace ale potrvá déle a stáhne víc dat." @(
                        @('Přihlaste se do Sophos Central', 'central.sophos.com účtem IT.'),
                        @('Stáhněte nový instalátor', 'Zařízení → Instalátory → Endpoint Protection → Windows.'),
                        @('Nahraďte soubor na NAS', "Přejmenujte ho na SophosSetup_new.exe a uložte do $nasRoot\SophosInstall (starý přepište)."),
                        @('Nebo pokračujte se starým', 'Sophos se po instalaci sám aktualizuje, jen to potrvá déle.'), $script:Recheck
                    ) $sHow $true))
        }
        else {
            $checks.Add((New-IpCheck 'sophos' 'Sophos' 'Instalátor Sophos' 'ok' 'v pořádku' 'Instalátor Sophos je v pořádku' "$($sc.Rel) · verze $($sc.Version) · stáří $age dní · podpis $($sig.Status)." @() $sHow $true))
        }
    }

    # --- písmo
    $fHow = 'Hledá code128.ttf na NAS a zjistí, zda je písmo na PC už nainstalované a pro koho.'
    $fc = if ($haveIndex) { @(Get-IpCandidates -Index $Index -ItemId 'font-code128') | Select-Object -First 1 } else { $null }
    $sysFont = Test-Path -LiteralPath (Join-Path $env:windir 'Fonts\code128.ttf')
    $userFont = $User -and $User.ProfilePath -and (Test-Path -LiteralPath (Join-Path $User.ProfilePath 'AppData\Local\Microsoft\Windows\Fonts\code128.ttf'))
    if ($sysFont) {
        $checks.Add((New-IpCheck 'font' 'Písmo' 'Písmo Code128' 'ok' 'nainstalováno' 'Písmo Code128 už je nainstalované pro všechny' 'Písmo je v C:\Windows\Fonts – instalace se přeskočí.' @() $fHow $true))
    }
    elseif (-not $Nas.Ok) {
        $checks.Add((New-IpCheck 'font' 'Písmo' 'Písmo Code128' 'err' 'neověřeno' 'Nelze ověřit – NAS je odpojený' 'Soubor písma je jen na NAS, a ten teď neodpovídá.' $nasDownSteps $fHow $true))
    }
    elseif (-not $fc) {
        $checks.Add((New-IpCheck 'font' 'Písmo' 'Písmo Code128' 'err' 'chybí' 'Písmo Code128 chybí' 'Na NAS není soubor code128.ttf. Písmo je povinné a bez souboru se nenainstaluje.' @(
                    @('Najděte soubor písma', 'Soubor code128.ttf má IT nebo dodavatel tiskárny štítků.'),
                    @('Nahrajte ho na NAS', "Do $nasRoot (kořen) nebo do podsložky max. 2 úrovně hluboko."), $script:Recheck
                ) $fHow $true))
    }
    elseif ($userFont) {
        $checks.Add((New-IpCheck 'font' 'Písmo' 'Písmo Code128' 'warn' 'jen 1 uživatel' 'Písmo je na PC jen pro jednoho uživatele' "Code128 je nainstalované jen v profilu $($User.Short). Ostatní účty a tiskové služby ho nevidí, tisk štítků pod jiným účtem nebude fungovat." @(
                    @('Nechte Písmo Code128 vybrané', 'Je to povinná položka, vybraná je automaticky.'),
                    @('Ponechte rozsah »Všichni«', 'V hlavním okně u řádku Písmo Code128 – je to doporučená volba. Kopie v profilu nevadí, nic se nemaže.'),
                    @('Po instalaci se odhlaste a přihlaste', 'Některé programy (tisk štítků) načtou nové písmo až po novém přihlášení.')
                ) $fHow $true))
    }
    else {
        $checks.Add((New-IpCheck 'font' 'Písmo' 'Písmo Code128' 'ok' 'v pořádku' 'Písmo Code128 je připravené' "Soubor $($fc.Rel) nalezen, rodina »$($fc.Product)«." @() $fHow $true))
    }

    # --- disk
    $free = 0; try { $free = [Math]::Round((Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1) } catch { }
    $dHow = "Volné místo na $env:SystemDrive; varování pod $($Settings.MinFreeGb) GB, pod $($Settings.BlockFreeGb) GB se instalace zastaví."
    if ($free -lt $Settings.BlockFreeGb) {
        $checks.Add((New-IpCheck 'disk' 'Disk' 'Volné místo na disku' 'err' "$free GB" 'Na disku není místo' "Na $env:SystemDrive je jen $free GB volného místa. Instalace by selhaly." @(
                    @('Vysypte koš a smažte dočasné soubory', 'Nastavení → Systém → Úložiště → Dočasné soubory → Odebrat soubory.'),
                    @('Uvolněte aspoň 5 GB', 'Velké soubory přesuňte na síťový disk nebo OneDrive.'), $script:Recheck
                ) $dHow $true))
    }
    elseif ($free -lt $Settings.MinFreeGb) {
        $checks.Add((New-IpCheck 'disk' 'Disk' 'Volné místo na disku' 'warn' "$free GB" 'Na disku je málo místa' "Na $env:SystemDrive je $free GB volného místa. Malé programy se vejdou, Microsoft 365 nebo CAD nemusí." @(
                    @('Vysypte koš a smažte dočasné soubory', 'Nastavení → Systém → Úložiště → Dočasné soubory → Odebrat soubory.'), $script:Recheck
                ) $dHow))
    }
    else {
        $checks.Add((New-IpCheck 'disk' 'Disk' 'Volné místo na disku' 'ok' "$free GB volných" 'Na disku je dost místa' "Na $env:SystemDrive je $free GB volného místa." @() $dHow))
    }

    # --- index
    $iHow = 'Porovná uložený index (cesta, velikost, čas změny) s obsahem NAS; změněné soubory přečte znovu.'
    if (-not $Index -or -not $Index.ScannedAt) {
        $checks.Add((New-IpCheck 'index' 'Index' 'Obsah NAS (index instalátorů)' 'err' 'chybí' 'Obsah NAS není známý' 'NAS se zatím nepodařilo prohledat a uložený index neexistuje. Instalovat jde jen z internetu.' $nasDownSteps $iHow))
    }
    elseif ($Index.FromCache) {
        $checks.Add((New-IpCheck 'index' 'Index' 'Obsah NAS (index instalátorů)' 'warn' 'uložený' 'Používá se uložený index' ("NAS je odpojený, zobrazuje se index z {0:d. M. yyyy H:mm}. Slouží jen pro přehled, z NAS teď instalovat nejde." -f $Index.ScannedAt) $nasDownSteps $iHow))
    }
    else {
        $d = '{0} souborů · {1} programů rozpoznáno · {2} ve více verzích · {3} nerozpoznaných · prohledáno za {4} s' -f $Index.Stats.Files, $Index.Stats.Recognized, $Index.Stats.Multi, @($Index.Unrecognized).Count, $Index.Stats.Seconds
        $checks.Add((New-IpCheck 'index' 'Index' 'Obsah NAS (index instalátorů)' 'ok' 'aktuální' 'Index NAS je aktuální' $d @() $iHow))
    }
    return $checks.ToArray()
}

Export-ModuleMember -Function @('Find-IpWinget', 'Test-IpNas', 'Test-IpInternet', 'Get-IpHealth')
