# Instalace programů v3.1

Nástroj pro správce IT na přípravu a správu firemních počítačů s Windows 10 a 11. Je napsaný ve Windows
PowerShellu 5.1 s okenním rozhraním (WPF), takže na PC není potřeba nic doinstalovávat.

**Co umí**

- **Instalace programů z NAS** (`\\FS01\backup\IT\Programy\_SW`) – offline a tiše na pozadí, podle balíčků
  (Nový počítač, Kancelář, Spedice, Technik, Vzdálená podpora) nebo jednotlivě. Když instalátor na NAS
  chybí nebo selže, použije internet (winget).
- **Rozpozná obsah NAS sám** – verze a nové soubory pozná podle pravidel v `config/catalog.json`, bez úprav skriptu.
- **Úvodní kontrola** – NAS, internet, oprávnění, Sophos, písmo, místo na disku; u každého problému postup řešení.
- **Instalace bez UAC** pro běžné uživatele přes systémovou úlohu (nasazení GPO).
- **Jazyk uživatelů** – klávesnice, jazyk Windows a formáty pro jednotlivé uživatele, návrh podle AD; mazání profilů.
- **Záloha a přenos dat uživatele** – plocha, dokumenty, stažené soubory, obrázky a profily prohlížečů
  (záložky, nebo celý profil i s hesly) na NAS / disk a obnova na jiném PC.
- **O instalátoru** – technické údaje (kde je aplikace na NAS, cíl záloh, logy), správa a řešení problémů.

**Rychlý start**

1. Celou složku nakopírujte na NAS (`\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3`).
2. Na plochu PC dejte jen `Instalace-programu.cmd` – zbytek aplikace se spouští z NAS.
3. Dvojklik → aplikace si řekne o práva správce (nebo instaluje přes systémovou úlohu bez UAC).

Cesty k serverům jsou firemní; jiné prostředí upraví `config/settings.json` (cesty, limity),
`config/catalog.json` (programy) a `config/languages.json` (jazyky poboček).

**Verze a historie:** každá verze je v tomto repozitáři jako tag (`v3.0`, `v3.1`, …) – viz
[Releases / Tags](https://github.com/lukasobrucnik/instalace-programu/tags) a sekce Historie níže.

## Kde co je (technické údaje – vidíte je i v okně O instalátoru)

| Co | Kde | Kde se mění |
|---|---|---|
| Aplikace (backend) | `\\FS01\backup\IT\Programy\_IT\ProgramInstalace\v3` | registr `HKLM\SOFTWARE\InstalaceProgramu` `NasPath` (O instalátoru → Změnit adresu na NAS, nebo GPO), jinak `settings.json` `deployPath` + řádek `set "NAS=..."` ve spouštěči |
| Spouštěč na plochu | `Instalace-programu.cmd` – na plochu stačí jen on | – |
| Instalátory | `\\FS01\backup\IT\Programy\_SW` | `settings.json` `sourceRoots` |
| Zálohy uživatelů | `\\FS01\backup\IT\Backup\Uzivatele-profily` (vznikne při první záloze) | `settings.json` `backupRoot`, v okně jde zvolit jiný cíl |
| Logy | `C:\ProgramData\InstalaceProgramu\Logs` (bez práv správce `%LOCALAPPDATA%\InstalaceProgramu\Logs`) | `settings.json` `dataDirectory` |
| Místní kopie pro systémovou úlohu | `C:\Program Files\InstalaceProgramu` | `settings.json` `appDirectory` |

Adresa v HKLM: zapisovat smí jen správce. Kdyby ji mohl změnit běžný uživatel, podstrčil by skript,
který se pak spustí s právy správce. Proto ne soubor vedle spouštěče ani `%LOCALAPPDATA%`.

## Záloha a přenos dat uživatele

Tlačítko **Záloha uživatele** v horní liště.

- **Zálohovat:** uživatel → co (plocha, dokumenty, stažené soubory, obrázky; prohlížeče Chrome, Edge,
  Brave, Opera, Firefox: *jen záložky* nebo *celý profil* = záložky, hesla, historie, rozšíření,
  nastavení, bez mezipaměti) → kam. Výsledek: `<cíl>\<POČÍTAČ>_<login>_<rrrrMMdd-HHmm>\` s `backup.json`
  (obsah a výsledek) a `_robocopy.log`.
- **Obnovit ze zálohy:** záloha → uživatel na tomto PC (musí tu mít profil) → co. Novější soubory se
  nepřepisují (`/XO`). Celý profil prohlížeče: stávající se odloží jako `*.pred-obnovou-<datum>`.
- Složky se hledají podle registru uživatele (User Shell Folders) – i přesměrované do OneDrive.
  Složka přesměrovaná na server se nezálohuje. Soubory jen v cloudu se nestahují.
- **Hesla:** Chrome / Edge / Brave / Opera šifruje Windows (DPAPI) klíčem účtu. S celým profilem se
  zálohují i klíče (`AppData\Roaming\Microsoft\Protect`) a na novém PC je přečte jen **stejný doménový
  účet**. Jiný účet: synchronizace prohlížeče nebo export CSV. Firefox přenese hesla vždy. Přihlášení na
  webech (cookies) se většinou nepřenese.
- Kopíruje `robocopy /E /XJ /COPY:DAT /MT:8 /XA:O` (jako správce `/B`). Na zdrojovém PC se nic nemění.
  Po dokončení se práva složky zálohy omezí na SYSTEM, správce, toho, kdo zálohoval, a vlastníka dat.
- Bez práv správce jen vlastní profil (pod vlastním účtem a jeho právy na NAS). Systémová úloha se pro
  zálohy nepoužívá (SYSTEM nemá zápis na NAS).
- Spuštěný prohlížeč okno nabídne zavřít (otevřené soubory by nešly zkopírovat).

## Výkon (slabší PC)

Úlohy na pozadí sdílí jeden fond runspace (moduly se načtou jednou). Seznam balíčků Appx se drží
10 minut a po instalaci se obnoví. Průběžná kontrola stavu (každou minutu) běží jen když je aplikace
v popředí; po návratu do okna se hned doběhne.

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
  spouštěč si skript najde na NAS sám; na plochu stačí jen tento jeden soubor). Na dotaz Windows klikněte Ano.
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
src/Backup.psm1           záloha a obnova dat uživatele (složky, prohlížeče, DPAPI), robocopy
tools/Install-Broker.ps1  nasazení systémové úlohy (GPO, jako SYSTEM)
tools/Start-Broker.ps1    spouští systémová úloha (obnoví kopii z NAS, zpracuje požadavky)
tools/Test-Broker.ps1     ověření na PC (spouštět jako běžný uživatel)
src/Gui.psm1, MainWindow.xaml   okno
tools/                    pomůcky pro správce a vývoj (BOM, zástupce, testy)
```
Logy: `C:\ProgramData\InstalaceProgramu\Logs`. Soubory `.ps1/.psm1` musí být v UTF-8 s BOM
(`tools\Add-Bom.ps1`) a v řetězcích v uvozovkách "" se nesmí používat české „“ – PowerShell je bere jako konec řetězce.
Soubory `.cmd` musí být **bez** BOM a s konci řádků CRLF (`Add-Bom.ps1` to od v3.1 hlídá sám).

## Historie

- **3.1 (2026-11-24)** – okno Záloha uživatele (záloha / obnova), technické údaje a řešení problémů
  v okně O instalátoru, změna adresy backendu (HKLM `NasPath`), spouštěč čte adresu z registru,
  odlehčení pro slabší PC. Opraveno: ikona `Instalace-programu.ico` byla poškozená (starý `Add-Bom.ps1`
  ji přepsal jako text) a spouštěče `.cmd` měly BOM.
- 3.0 (2026-11-10) – instalace bez UAC (systémová úloha), jazyk uživatelů, mazání profilů.
