# Rollout auf weitere SoundTouch-Boxen

Anleitung, um eine zusaetzliche Bose SoundTouch auf dieses Repository
umzustellen. Hintergruende stehen in [KNOWLEDGE.md](KNOWLEDGE.md).

---

## 0. Voraussetzungen

- **Dieses Repository muss oeffentlich sein.** `raw.githubusercontent.com`
  liefert private Inhalte nur mit Token aus, und die Box kann keinen
  mitschicken.
- Firmware der Box **27.x oder neuer**.
- Die Box muss vom Arbeitsplatz per Unicast erreichbar sein (Ports 8090 und
  17000). Getrennte VLANs sind kein Hindernis, solange die Firewall es
  zulaesst. mDNS wird nicht gebraucht.

```powershell
. .\tools\Soundtouch.ps1
```

---

## 1. Box finden

```powershell
Find-Soundtouch -Subnet "192.0.2"
```

Liefert alle erreichbaren Boxen samt Modell, Firmware und der Spalte
`Supported`. Steht dort `False`, ist die Firmware zu alt - dann hier abbrechen.

Alternativ direkt, wenn die IP bekannt ist:

```powershell
Get-SoundtouchInfo -IPAddress 192.0.2.10
```

---

## 2. Ausgangszustand sichern

Immer vor dem ersten Eingriff. Die Dateien dienen spaeter als Referenz.

```powershell
$ip = "192.0.2.10"
$sicherung = "$env:USERPROFILE\Documents\soundtouch-backup\$ip"
New-Item -ItemType Directory -Path $sicherung -Force | Out-Null

foreach ($ep in @("info","presets","sources","now_playing")) {
    $r = Invoke-WebRequest "http://${ip}:8090/$ep" -UseBasicParsing
    $t = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { $r.Content }
    Set-Content -Path (Join-Path $sicherung "$ep.xml") -Value $t -Encoding UTF8
}
```

Besonders `sources.xml` genau ansehen: Steht dort eine **Spotify-Quelle mit
`status="READY"`**, geht diese Verknuepfung bei Schritt 3b verloren und laesst
sich voraussichtlich nicht wiederherstellen. Siehe
[KNOWLEDGE.md, Abschnitt 6](KNOWLEDGE.md#der-preis-der-installation).

---

## 3. Quelle LOCAL_INTERNET_RADIO bereitstellen

Zuerst pruefen, wie die Box aufgestellt ist:

```powershell
Test-SoundtouchSetup -IPAddress $ip
```

Ist die Zeile `Quelle LOCAL_INTERNET_RADIO` bereits `OK`, direkt zu **Schritt 4**
springen.

### 3a. Box wurde bereits mit SoundPloy praepariert

Dann existieren `Sources.xml` und `OverrideSdkPrivateCfg.xml` schon und es muss
nur die Registry-URL umgebogen werden. Kein Download noetig:

```powershell
Install-BoseRadio -IPAddress $ip `
    -OldUrl "http://soundploy.gmuth.de/v2/registry.json" -Confirm
```

Die Box startet neu (1-3 Minuten).

### 3b. Fabrikfrische Box

Hier fehlen beide Dateien, ein `sed` laeuft ins Leere. Sie muessen erst angelegt
werden. Dafuer gibt es zwei Wege:

**Weg 1, empfohlen:** einmalig den Installer von SoundPloy laufen lassen, der
ueber einfaches HTTP arbeitet und nachweislich funktioniert - danach sofort auf
dieses Repo umbiegen. Das vertraut dem fremden Server genau einen Bootvorgang
lang.

```
# Telnet auf Port 17000
envswitch boseurls set ";curl soundploy.gmuth.de/v2_install|sh" ;
sys reboot
```

Nach dem Neustart weiter mit **3a**.

**Weg 2:** [`device/install.sh`](device/install.sh) aus diesem Repo per `curl`
laden. Setzt voraus, dass der `curl` auf der Box HTTPS beherrscht und Redirects
folgt - **beides ist nicht verifiziert**.

```
envswitch boseurls set ";curl -L https://raw.githubusercontent.com/fkappen/bose/main/device/install.sh|sh" ;
sys reboot
```

---

## 4. Presets setzen

```powershell
Set-SoundtouchPresetSet -IPAddress $ip -ProfileName "standard"
```

Profile liegen in [`presets.json`](presets.json). Fuer eine Box mit anderer
Belegung dort ein zweites Profil anlegen:

```json
{
  "profile": {
    "standard": { "1": "swr4-koblenz", "2": "hr4-mittelhessen" },
    "kueche":   { "1": "oldie-antenne", "2": "radio-paloma" }
  }
}
```

Einzelne Taste:

```powershell
Set-SoundtouchPreset -IPAddress $ip -Preset 4 -Slug "antenne-bayern"
```

`Set-SoundtouchPreset` prueft vor dem Schreiben, ob die Senderdatei wirklich
abrufbar ist, und verweigert sonst den Dienst. So landet kein totes Preset auf
der Taste.

---

## 5. Boot-Hook entschaerfen

Nach erfolgreicher Installation sollte in `boseurls` kein ausfuehrbarer Befehl
mehr stehen, sonst arbeitet die Box bei jedem Start eine Anweisung von aussen ab.

```powershell
Reset-BoseBootHook -IPAddress $ip -Confirm
```

**Ungeprueft.** Der echte Werkszustand dieser Variable ist nicht bekannt und
laesst sich auch nicht auslesen. Die Funktion setzt beide Felder auf `;true`,
also einen Befehl ohne Wirkung. Danach unbedingt Schritt 6 wiederholen, um
sicherzugehen, dass die Box weiterhin sauber hochkommt.

---

## 6. Pruefen

```powershell
Test-SoundtouchSetup -IPAddress $ip
```

Erwartetes Ergebnis:

```
Pruefung                     Ergebnis  Detail
--------                     --------  ------
Erreichbar                   OK        SoundTouch 10 / AABBCCDDEEFF
Firmware >= 27               OK        27.0.6...
Quelle LOCAL_INTERNET_RADIO  OK        READY
Presets auf eigenem Repo     OK        5 eigen, 0 fremd
Senderdateien abrufbar       OK        0 von 5 nicht erreichbar
```

Abschliessend eine Preset-Taste am Geraet druecken und hoeren, ob Ton kommt. Die
API-Pruefung allein belegt die Wiedergabe nicht.

---

## Wenn etwas schiefgeht

| Symptom | Ursache | Abhilfe |
|---|---|---|
| `Senderdatei nicht erreichbar` | Repo privat oder Datei nicht gepusht | Repo oeffentlich schalten, `git push` |
| Quelle bleibt `fehlt` | `Sources.xml` fehlt auf der Box | Schritt 3b |
| Preset stumm, andere gehen | Stream-URL veraltet | Datei mit `New-StationFile` neu erzeugen |
| Box nicht auffindbar | falsches Subnetz oder Firewall | `Find-Soundtouch` im richtigen Subnetz, Firewallregel pruefen |
| Alles tot nach Neustart | Boot-Hook zerschossen | Telnet 17000, `envswitch boseurls set ";true" ";true"`, `sys reboot` |

Die Box laesst sich per Werksreset immer wieder in den Auslieferungszustand
bringen. Presets sind reine Konfiguration und jederzeit ueberschreibbar.
