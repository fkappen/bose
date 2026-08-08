# Bose SoundTouch ohne fremde Cloud

Bose hat den SoundTouch-Cloud-Dienst im Februar 2026 eingestellt und die
Server am 6. Mai 2026 endgueltig abgeschaltet. Damit sind alle TuneIn-Presets
tot. Dieses Repository bringt Internetradio zurueck, ohne dass die Box von
einem fremden Server abhaengt.

Der Lautsprecher fragt im Betrieb ausschliesslich **dieses Repository** ab.
Nichts von Bose, nichts von einem Dritten.

> **Wichtig:** Das Repository muss **oeffentlich** sein.
> `raw.githubusercontent.com` liefert private Inhalte nur mit Token aus, und die
> Box kann keinen mitschicken.

- Weitere Box einrichten: [ROLLOUT.md](ROLLOUT.md)
- Technische Details, Formate und Fallstricke: [KNOWLEDGE.md](KNOWLEDGE.md)

---

## Wie es funktioniert

Die SoundTouch-Firmware kennt eine Quelle `LOCAL_INTERNET_RADIO`. Fuer einen
Sender ruft sie eine URL auf und erwartet dort ein kleines JSON, das die
eigentliche Stream-Adresse enthaelt. Diese URL ist frei waehlbar und darf
absolut sein.

Genau das nutzt dieses Repo aus: Jeder Sender ist eine **statische
JSON-Datei**. Kein PHP, kein Server, keine Datenbank.

```
Preset-Taste gedrueckt
        |
        v
https://raw.githubusercontent.com/fkappen/bose/main/stations/swr4-koblenz.json
        |
        v
{ "audio": { "streamUrl": "https://liveradio.swr.de/sw282p3/swr4ko/" } }
        |
        v
Box spielt den Stream direkt vom Sender
```

---

## Abhaengigkeiten

Was im Betrieb noch nach draussen geht:

| Ziel | Wofuer | Vermeidbar? |
|---|---|---|
| Dieses GitHub-Repo | Senderdateien, `registry.json` | Ja, jeder statische Webserver tut es |
| Die Radiosender selbst | Der Audiostream | Nein, das ist der Sinn der Sache |

Was **nicht** mehr gebraucht wird:

- Die Bose-Cloud (abgeschaltet)
- `soundploy.gmuth.de` (fremder Hobbyserver)
- `radio-browser.info` im Betrieb

`radio-browser.info` wird nur noch benutzt, wenn ein **neuer Sender angelegt**
wird, um dessen Stream-URL nachzuschlagen. Die Box selbst ruft es nie auf.

> **Ehrlich bleiben:** GitHub ist auch ein Cloud-Dienst. Der Unterschied ist,
> dass es dein Konto, dein Repository und deine Dateien sind. Faellt GitHub
> weg oder willst du es nicht mehr, aenderst du **eine** URL und legst die
> Dateien woanders hin, zum Beispiel auf den eigenen Home Assistant.

---

## Verifikationsstand

Live geprueft gegen eine **SoundTouch 10**, Firmware `27.0.6`,
`moduleType=sm2`, `variant=rhino`:

| | Status |
|---|---|
| Box laedt eine statische JSON-Datei von GitHub per HTTPS und spielt sie | **bestaetigt** |
| Zertifikat von GitHub wird von der Box akzeptiert | **bestaetigt** |
| Presets per `POST /storePreset` schreibbar, ohne Tastendruck am Geraet | **bestaetigt** |
| Presets zeigen auf dieses Repo, Wiedergabe bestaetigt | **bestaetigt** |
| Registry per `sed` umgebogen, Quelle bleibt nach Neustart `READY` | **bestaetigt** |
| Box ruft `bmxRegistryUrl` tatsaechlich per HTTPS ab | **wahrscheinlich** (1) |
| curl auf der Box beherrscht HTTPS | ungeprueft (nicht noetig) |

(1) Nach der Umstellung und einem Neustart bleibt alles funktionsfaehig. Ob
die Registry wirklich neu geholt oder aus dem Geraetezustand bedient wird,
zeigt sich erst nach Ablauf von `askAgainAfter` (24 Stunden). Details in
[KNOWLEDGE.md](KNOWLEDGE.md#zur-registry-ueber-https).

---

## Einrichtung

### Voraussetzungen

- Firmware 27.x oder neuer. Pruefen: `http://<box-ip>:8090/info`
- Die Box muss vom PC aus per Unicast erreichbar sein (Ports 8090 und 17000).
  Getrennte VLANs sind kein Problem, solange die Firewall es zulaesst.
- mDNS wird **nicht** gebraucht.

### Schritt 1: Presets auf dieses Repo umstellen

Das geht ohne jeden Eingriff am Geraet, rein ueber die HTTP-API.

```powershell
. .\tools\Soundtouch.ps1

$ip = "192.0.2.10"
Get-SoundtouchInfo -IPAddress $ip

Set-SoundtouchPreset -IPAddress $ip -Preset 1 -Slug "swr4-koblenz"
Set-SoundtouchPreset -IPAddress $ip -Preset 2 -Slug "hr4-mittelhessen"
Set-SoundtouchPreset -IPAddress $ip -Preset 3 -Slug "ndr1-welle-nord"
Set-SoundtouchPreset -IPAddress $ip -Preset 5 -Slug "oldie-antenne"
Set-SoundtouchPreset -IPAddress $ip -Preset 6 -Slug "radio-paloma"

Get-SoundtouchPreset -IPAddress $ip | Format-Table -AutoSize
```

Damit ist `radio-browser.info` aus dem Betrieb raus. Voraussetzung ist, dass
die Quelle `LOCAL_INTERNET_RADIO` auf der Box bereits aktiv ist.

### Schritt 2: Registry auf dieses Repo umbiegen

Erst dieser Schritt loest die Box von `soundploy.gmuth.de`. Er braucht
Telnet auf Port 17000 und einen Neustart.

Der **empfohlene** Weg kommt ohne Download aus und aendert nur die eine
Zeile in der bestehenden Konfigurationsdatei:

```
envswitch boseurls set ";sed -i s#http://soundploy.gmuth.de/v2/registry.json#https://raw.githubusercontent.com/fkappen/bose/main/registry.json#g /mnt/nv/OverrideSdkPrivateCfg.xml" ;
sys reboot
```

Danach den Boot-Hook wieder entfernen, damit die Box beim Start nichts mehr
ausfuehrt. Alternativ liegt in [`device/install.sh`](device/install.sh) die
Variante mit `curl`; sie setzt aber voraus, dass der curl auf der Box HTTPS
kann, was nicht geprueft ist.

Kontrolle nach dem Neustart:

```powershell
Invoke-WebRequest "http://192.0.2.10:8090/sources" -UseBasicParsing
```

`LOCAL_INTERNET_RADIO` muss dort mit `status="READY"` auftauchen.

---

## Einen Sender hinzufuegen

```powershell
. .\tools\Soundtouch.ps1

# 1. Suchen
Find-RadioStation -Name "Antenne Bayern" | Format-Table Name, StationUuid, StreamUrl

# 2. Datei erzeugen
Find-RadioStation -Name "Antenne Bayern" | Select-Object -First 1 |
    New-StationFile -Slug "antenne-bayern"

# 3. Committen und pushen, sonst findet die Box die Datei nicht
git add stations/antenne-bayern.json
git commit -m "Sender Antenne Bayern"
git push

# 4. Auf eine Taste legen
Set-SoundtouchPreset -IPAddress 192.0.2.10 -Preset 4 -Slug "antenne-bayern"
```

Eine Senderdatei ist bewusst simpel und laesst sich auch von Hand schreiben:

```json
{
  "name": "Beispiel FM",
  "streamType": "liveRadio",
  "imageUrl": "",
  "audio": {
    "isRealtime": true,
    "hasPlaylist": false,
    "streamUrl": "https://beispiel.de/stream.mp3"
  }
}
```

---

## Aktuelle Belegung

| Taste | Sender | Datei |
|---|---|---|
| 1 | SWR4 Koblenz | [`stations/swr4-koblenz.json`](stations/swr4-koblenz.json) |
| 2 | hr4 Mittelhessen | [`stations/hr4-mittelhessen.json`](stations/hr4-mittelhessen.json) |
| 3 | NDR 1 Welle Nord | [`stations/ndr1-welle-nord.json`](stations/ndr1-welle-nord.json) |
| 4 | Antenne Sylt | [`stations/antenne-sylt.json`](stations/antenne-sylt.json) |
| 5 | OLDIE ANTENNE | [`stations/oldie-antenne.json`](stations/oldie-antenne.json) |
| 6 | Radio Paloma | [`stations/radio-paloma.json`](stations/radio-paloma.json) |

---

## Aufbau

```
README.md                  Diese Datei
ROLLOUT.md                 Schritt-fuer-Schritt fuer weitere Boxen
KNOWLEDGE.md               Wissensbasis: API, Formate, Fallstricke, Verifikationsstand
.nojekyll                  Noetig, damit GitHub Pages die JSON-Dateien ausliefert
registry.json              Service-Registry, die die Box beim Start liest
presets.json               Profile fuer den Rollout (Taste -> Sender)
stations/*.json            Ein Sender pro Datei
stations/index.json        Katalogverzeichnis (Slug -> Name, UUID, URL)
device/Sources.xml         Schaltet die Quelle LOCAL_INTERNET_RADIO frei
device/OverrideSdkPrivateCfg.xml   Zeigt bmxRegistryUrl auf dieses Repo
device/install.sh          Optionale Installation per curl
tools/Soundtouch.ps1       PowerShell-Werkzeuge (5.1 kompatibel)
```

## Werkzeug

Direkt aufgerufen startet ein Menue:

```powershell
.\tools\Soundtouch.ps1
```

```
  ==================================================================
   Bose SoundTouch Verwaltung                              v2.0.0
  ==================================================================

   Sender lokal : 104
   Geraet       : 192.0.2.10  SoundTouch 10  (Firmware 27)

  ------------------------------------------------------------------
   [1]  Geraete suchen und auswaehlen
   [2]  Status des gewaehlten Geraets
   [3]  Presets anzeigen
   [4]  Einrichtung / Migration  (gefuehrt)
   [5]  Presets aus Profil setzen
   [6]  Einzelnes Preset setzen
   [7]  Senderkatalog aktualisieren (Top 100 DE)
   [8]  Sender suchen und hinzufuegen
   [9]  Registry umbiegen (Telnet, Neustart)
   [R]  Boot-Hook entschaerfen
   [Q]  Beenden
  ------------------------------------------------------------------
```

Punkt **[4]** ist der gefuehrte Weg fuer eine neue Box: Zustand pruefen,
vorhandene Presets migrieren, fehlende Senderdateien anlegen, Registry
umbiegen, Presets setzen, Ergebnis kontrollieren.

Wird das Skript dot-gesourct, startet kein Menue und die Funktionen stehen
einzeln bereit:

```powershell
. .\tools\Soundtouch.ps1
```

| Funktion | Zweck |
|---|---|
| `Find-Soundtouch` | Boxen suchen (TCP-Scan, kein mDNS noetig) |
| `Get-SoundtouchInfo` | Modell, Firmware, Eignung |
| `Test-SoundtouchSetup` | Gesamtpruefung inkl. Erreichbarkeit der Senderdateien |
| `Find-RadioStation` | Sender bei radio-browser suchen |
| `New-StationFile` | `stations/<slug>.json` erzeugen |
| `Update-StationCatalog` | Top-N eines Landes holen und aktualisieren |
| `Test-StationFiles` | Alle Senderdateien auf erreichbare Streams pruefen |
| `Test-StationStream` | Einzelne Stream-URL pruefen (ICY-tauglich) |
| `Convert-SoundtouchPreset` | Bestehende Presets migrieren, fehlende Dateien anlegen |
| `Get-SoundtouchPreset` | Belegung auslesen |
| `Set-SoundtouchPreset` | Einzelne Taste setzen |
| `Set-SoundtouchPresetSet` | Profil aus `presets.json` anwenden |
| `Install-BoseRadio` | Registry auf dieses Repo umbiegen (Telnet) |
| `Reset-BoseBootHook` | Boot-Hook entschaerfen |
| `Wait-Soundtouch` | Auf Neustart warten |

## Senderkatalog

`stations/` enthaelt die 100 meistgehoerten deutschen Sender plus die
handgepflegten. `stations/index.json` haelt fest, welcher Slug zu welchem
Sender gehoert.

Aktualisieren, wenn Sender ihre Stream-URL geaendert haben:

```powershell
. .\tools\Soundtouch.ps1
Update-StationCatalog -Top 100 -CountryCode DE
git add stations/ ; git commit -m "Senderkatalog aktualisiert" ; git push
```

Ein `-WhatIfOnly` zeigt vorher an, was sich aendern wuerde. Handgepflegte
Sender, die nicht in der Top-Liste stehen, bleiben unberuehrt.

---

## Wartung

Der Preis der Unabhaengigkeit: Aendert ein Sender seine Stream-URL, faellt
das hier nicht automatisch nach. Dann die betroffene Datei neu erzeugen:

```powershell
Find-RadioStation -Name "SWR4 Koblenz" | Select-Object -First 1 |
    New-StationFile -Slug "swr4-koblenz"
```

Zum Pruefen aller Sender reicht ein Blick, ob die Streams noch antworten.

---

## Auf GitHub Pages umstellen

`raw.githubusercontent.com` funktioniert ohne jede Einrichtung und ist am
Geraet erprobt, ist aber nicht als Dauerlast-Endpunkt gedacht. Fuer eine
handvoll Abrufe pro Tag ist das unkritisch.

Wer Pages nutzen will, braucht die Datei **`.nojekyll`** im Wurzelverzeichnis.
Ohne sie verarbeitet Jekyll das Repo: die Wurzel wird als HTML ausgeliefert,
`registry.json` und `stations/*.json` geben aber 404. Die Datei liegt hier
bereits bei.

Danach in [`tools/Soundtouch.ps1`](tools/Soundtouch.ps1) die Variablen
`$script:StationBaseUrl` und `$script:RegistryUrl` sowie die `bmxRegistryUrl`
in [`device/OverrideSdkPrivateCfg.xml`](device/OverrideSdkPrivateCfg.xml) auf
`https://fkappen.github.io/bose/...` umstellen und die Presets neu setzen.

---

## Sicherung

Der Lautsprecher laedt seine Senderdateien von `raw.githubusercontent.com`.
Wird dieses Repository geloescht, umbenannt oder auf **privat** gestellt,
spielt er kein Radio mehr - und zwar **ohne Fehlermeldung am Geraet**. Das
ist die eigentliche Schwachstelle des Aufbaus, nicht Datenverlust.

Es gibt drei Ebenen:

**1. OneDrive.** Das Repo liegt unter `OneDrive\Dokumente\Github\bose`,
inklusive `.git`. Arbeitskopie und komplette Historie werden also bereits
mitsynchronisiert.

**2. git-Bundle.** Eine einzelne Datei mit dem vollstaendigen Repository
samt Historie, rund 70 KB:

```powershell
.\tools\Backup-Repo.ps1
```

Liegt standardmaessig in `..\_backup-bose\`, behaelt die letzten 14 Staende
und warnt, wenn nicht committete Aenderungen vorliegen. Wiederherstellen:

```powershell
git clone "..\_backup-bose\bose-2026-08-09_0110.bundle" bose
cd bose
git remote add origin https://github.com/fkappen/bose.git
git push -u origin main
```

Entscheidend ist, dass das neue Repo wieder **`fkappen/bose`** heisst und
**oeffentlich** ist - dann stimmen die URLs in den Presets wieder und der
Lautsprecher laeuft ohne Eingriff am Geraet weiter.

**3. Zweites Remote (optional).** Ein Spiegel bei einem anderen Anbieter
oder auf eigener Infrastruktur:

```powershell
git remote add spiegel <url>
git push spiegel main
```

### Ausfall bemerken

Weil ein Ausfall am Geraet stumm bleibt, lohnt eine regelmaessige Kontrolle.
`Test-SoundtouchSetup` prueft genau das mit - die Zeile
*Senderdateien abrufbar* holt jede hinterlegte URL wirklich ab:

```powershell
. .\tools\Soundtouch.ps1
Test-SoundtouchSetup -IPAddress 192.0.2.10
```

## Zurueckbauen

Die Box laesst sich jederzeit auf Werkszustand zuruecksetzen. Die hier
gesetzten Presets sind reine Konfiguration und lassen sich mit
`Set-SoundtouchPreset` jederzeit ueberschreiben.

---

## Sicherheitshinweis

Der Weg, Konfiguration auf die Box zu bekommen, ist eine Command Injection in
die Geraetevariable `boseurls`. Bleibt dort ein `curl ... | sh` stehen, laedt
die Box bei **jedem** Start ein Skript aus dem Netz und fuehrt es aus. Nach
der Einrichtung deshalb den Hook wieder entfernen. Der `sed`-Weg oben laedt
gar nichts erst nach und ist auch aus diesem Grund vorzuziehen.

---

## Verwandte Projekte

- [gmuth/soundploy](https://github.com/gmuth/soundploy) - der Ansatz, auf dem
  die Erkenntnisse hier beruhen. Haengt dauerhaft am Server des Autors.
- [JRpersonal/streborn](https://github.com/JRpersonal/streborn) - deutlich
  umfangreicher: Go-Agent auf der Box, der die Bose-Cloud lokal nachbaut, mit
  Spotify Connect, DLNA und Multiroom. Die richtige Wahl, wenn es mehr als
  Radio sein soll.
