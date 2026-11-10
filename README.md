# Instalace programů v3

Instaluje firemní programy z NAS (`\\FS01\backup\IT\Programy\_SW`) – offline, tiše na pozadí.
Když program na NAS chybí nebo se z něj nenainstaluje, použije internet (winget).

## Nasazení na NAS

1. Celou složku `v3` (včetně `config`, `src`, `tools`) nakopírujte do
   `\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3`.
2. Na NAS spusťte jednou:
   `powershell -ExecutionPolicy Bypass -File \\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3\tools\New-NasShortcut.ps1`
   Vznikne `Instalace programů.lnk` s ikonou – ten jde přetáhnout na plochu kteréhokoli PC.
3. Do složky smí zapisovat jen IT. Skript běží s právy správce na každém PC – kdo ho může změnit, ovládne všechny počítače.

## Instalace bez práv správce (bez dotazu UAC)

Uživatel nepotřebuje heslo správce. Okno běží pod jeho účtem a programy nainstaluje systémová
úloha `InstalaceProgramu-Broker` (běží jako SYSTEM). Úlohu na PC jednou nasadí Domain Admin přes GPO:

1. **Práva na NAS:** skupina `Domain Computers` musí mít **čtení** na `\\FS01\backup\IT\Programy`
   (sdílení i NTFS). Úloha běží jako SYSTEM a na NAS přistupuje účtem počítače.
2. **GPO** (propojit s OU počítačů): Konfigurace počítače → Předvolby → Nastavení ovládacích panelů →
   Naplánované úlohy → Nový → **Okamžitá úloha (Windows 7 a novější)**:
   - Obecné: název `InstalaceProgramu-Nasazeni`, účet `NT AUTHORITY\System`, Spustit s nejvyššími oprávněními
   - Akce → Spustit program: `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`,
     argumenty `-NoProfile -ExecutionPolicy Bypass -File "\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3\tools\Install-Broker.ps1"`

   Proběhne při příští aktualizaci zásad (do 90 min nebo `gpupdate /force`), bez restartu.
   Spouštěcí skript počítače raději nepoužívejte: kvůli Rychlému spuštění Windows 10/11 neproběhne
   při běžném Vypnout, jen při Restartovat.
3. **Ověření na PC:** jako běžný uživatel spusťte
   `powershell -ExecutionPolicy Bypass -File \\FS01\...\v3\tools\Test-Broker.ps1`.
   Musí skončit „Vše v pořádku“.

Co úloha udělá: zkopíruje aplikaci do `C:\Program Files\InstalaceProgramu` (při každém spuštění ji
obnoví z NAS), zaregistruje úlohu a dá zástupce na veřejnou plochu. Odebrání: `Install-Broker.ps1 -Uninstall`.

Bezpečnost: uživatel úlohu smí jen spustit. Do úlohy předá jen ID programů z katalogu, verzi
a rozsah. Úloha si plán, cesty i příkazy sestaví sama z vlastního katalogu a indexu NAS.

Omezení: programy s oknem průvodce (`interactive`, Office z NAS, ZIP) a ruční výjimky z okna Obsah NAS
takto nainstalovat nejde. Úloha běží v neviditelné relaci a okno by nikdo neviděl. Na ty spusťte
`InstalaceProgramu.ps1 -Elevate` (UAC, účet správce). Bez nasazené úlohy aplikace funguje jako dřív (UAC).

## Spuštění

- Dvojklik na `Instalace programů.lnk` nebo `Instalace-programu.cmd` (z NAS i jako kopie na ploše –
  spouštěč si skript najde na NAS sám). Na dotaz Windows klikněte Ano.
- Při prvním spuštění se na veřejnou plochu vytvoří zástupce s ikonou.
- Když se nic neotevře: `Diagnostika.cmd` (viditelná konzole, vypíše co chybí).

## Příkazová řádka (jako správce)

```
InstalaceProgramu.ps1 -NoGui                     povinný základ bez okna
InstalaceProgramu.ps1 -Bundle kancelar           povinný základ + balíček
InstalaceProgramu.ps1 -Items 7zip,libreoffice -Scope user
InstalaceProgramu.ps1 -Bundle novy-pc -DryRun    jen vypíše plán, nic neinstaluje
InstalaceProgramu.ps1 -Scan                      co skript na NAS našel
InstalaceProgramu.ps1 -LanguageReport            uživatelé PC, doménový/místní, jazyk, návrh z AD
InstalaceProgramu.ps1 -SetLanguage de-AT -ForUser FIRMA\jnovak,FIRMA\pdvorak
InstalaceProgramu.ps1 -SetLanguage sk-SK -ForUser default    jazyk pro nové uživatele
InstalaceProgramu.ps1 -SetLanguage '' -ForUser FIRMA\jnovak  zrušit přiřazení
```
Návratové kódy: 0 OK, 1 něco selhalo, 2 chyba spuštění, 3010 OK + nutný restart.

## Jazyk uživatelů (pobočky v různých zemích)

Tlačítko **Jazyk uživatelů** v horní liště otevře samostatné okno:

- Seznam uživatelů s profilem na PC. U každého je vidět, jestli jde o **doménový**, **místní**
  nebo **Entra ID** účet (podle SID), jestli je přihlášený, jaký jazyk má teď, a údaje z AD
  (jméno, oddělení, město).
- **Návrh jazyka** z AD: atribut `preferredLanguage`, jinak země (`c`) podle `regions`
  v `config/languages.json`. Tlačítko „Použít návrhy z AD" ho vybere všem najednou.
- Výběr jazyka pro uživatele. Podle něj se nastaví **klávesnice**, **jazyk Windows**
  a **formáty a oblast** (lze odškrtnout, co se nastavit nemá). Ve stejném jazyce se pak
  instalují programy z internetu (`winget --locale`, jazyk Office).
- **Přidat doménového uživatele** z AD, který se na PC ještě nepřihlásil.
- **Celý počítač**: jazyk pro nové uživatele, jazyk systému pro programy bez Unicode,
  časové pásmo, chybějící jazykové balíčky Windows.

Kdy se změna projeví: přihlášenému uživateli hned (jazyk Windows až po odhlášení), ostatním
při příštím přihlášení. Zajišťuje to úloha `InstalaceProgramu-Jazyk`. Spouští se při přihlášení
pod uživatelem, bez práv správce, a každé přiřazení použije jen jednou. Pak si uživatel
může jazyk změnit sám. Přiřazení se ukládají do
`C:\ProgramData\InstalaceProgramu\Language\assignments.json` (zapisovat smí jen správce
nebo SYSTEM).

Chybějící jazyk Windows se doinstaluje: na Windows 11 a novějších Windows 10 přes
`Install-Language` (Windows Update), jinak ze souboru `*Language-Pack*<jazyk>*.cab` ve složce
`languagePackRoot` na NAS (balíček musí odpovídat buildu Windows). Pak je potřeba restart.

Kdo smí co: každý může nastavit jazyk komukoli i celému počítači. Správce to provede přímo,
běžný uživatel (bez UAC) přes systémovou úlohu. Úloha z okna převezme jen SID a ID jazyka,
účty a profily si zjistí sama a přijme jen hodnoty z `languages.json`. Každá změna se zapíše
do logu i se jménem toho, kdo ji udělal. Když má běžný uživatel smět nastavit jen sám sobě,
dejte v `config/settings.json` `"languageForAll": false`. Jazyky, klávesnice, GeoID a časová
pásma poboček se upravují v `config/languages.json`.

### Mazání profilů

V okně Jazyk uživatelů je u každého uživatele zaškrtávátko **smazat profil**. Tlačítkem
**Smazat vybrané profily…** se po potvrzení z PC smaže profil (složka `C:\Users\…` a záznam
v registru, přes `Win32_UserProfile`). U místních účtů lze v potvrzení smazat i samotný účet.
Doménové a Entra ID účty zůstávají, na PC se smaže jen jejich profil.

Nikdy se nesmaže: účet, pod kterým je okno spuštěné, uživatel přihlášený u PC, kdokoli právě
přihlášený, načtený nebo systémový profil a vestavěný účet Administrator.

Mazání smí jen správce. Běžnému uživateli (přes systémovou úlohu) ho povolíte v
`config/settings.json` volbou `"profileDeleteForAll": true`. Pozor: pak může smazat data kolegů.

Stažení chybějícího jazyka Windows (Windows Update) trvá 5–30 minut. Přiřazení, klávesnice
a formáty se proto nastaví hned, balíček se stahuje až potom a okno každých 30 s hlásí průběh.

## Změny na NAS

Nová verze, přejmenování nebo další verze programu se projeví samy při dalším spuštění – skript
NAS prohledává a pozná programy podle pravidel (`match`) v `config/catalog.json`.
Nový program, který skript nepozná, se objeví v okně **Obsah NAS** jako nerozpoznaný; trvale ho
přidáte novou položkou v `catalog.json` (vzorem jsou stávající položky). `-Scan` ukáže výsledek.

## Soubory

```
Instalace-programu.cmd    spouštěč (z NAS i z plochy)
Diagnostika.cmd           spuštění s viditelnou konzolí
InstalaceProgramu.ps1     vstup: okno i příkazová řádka
config/settings.json      cesty k NAS, časové limity
config/catalog.json       programy, pravidla rozpoznání, vyloučení, balíčky
config/languages.json     jazyky poboček: klávesnice, formáty, GeoID, časové pásmo, návrh podle země
src/Language.psm1         jazyk uživatelů: seznam uživatelů, AD, přiřazení, jazykové balíčky
tools/Apply-UserLanguage.ps1  nastaví jazyk pod uživatelem (při přihlášení / hned)
src/Common.psm1           nastavení, log, chráněné složky, přihlášený uživatel
src/NasIndex.psm1         prohledání NAS, metadata a verze, mezipaměť
src/Health.psm1           kontrolky a návody krok za krokem
src/Install.psm1          tichá instalace, záloha přes winget, chyby, hlídání oken
src/Broker.psm1           instalace bez práv správce: požadavky okno -> systémová úloha
tools/Install-Broker.ps1  nasazení systémové úlohy (GPO, jako SYSTEM)
tools/Start-Broker.ps1    spouští systémová úloha (obnoví kopii z NAS, zpracuje požadavky)
tools/Test-Broker.ps1     ověření na PC (spouštět jako běžný uživatel)
src/Gui.psm1, MainWindow.xaml   okno
tools/                    pomůcky pro správce a vývoj (BOM, zástupce, testy)
```
Logy: `C:\ProgramData\InstalaceProgramu\Logs`. Soubory `.ps1/.psm1` musí být v UTF-8 s BOM
(`tools\Add-Bom.ps1`) a v řetězcích v uvozovkách "" se nesmí používat české „“ – PowerShell je bere jako konec řetězce.
