# Sicherungskopie von streborn (STR)

Dieses Repository ist eine **Sicherungskopie** (Mirror) des Projekts
**STR / SoundTouch Reborn** von JRpersonal.

- **Original:** https://github.com/JRpersonal/streborn
- **Stand:** Commit `83b11ca`, gespiegelt am 2026-08-13
- **Lizenz:** MIT (STR-eigener Code) sowie GPL-3.0 (gebuendelte
  go-librespot-Komponente) - beide unveraendert uebernommen, siehe
  [`LICENSE`](LICENSE).

## Warum diese Kopie

Die Bose SoundTouch Boxen im Haushalt laufen jetzt mit STR. Damit haengt der
weitere Betrieb - insbesondere eine Neuinstallation oder ein Wiederherstellen
nach einem Werksreset - am Fortbestand des Original-Repositories und seiner
Releases. Diese Kopie ist die Rueckfallebene, falls das Original verschwindet,
umbenannt oder privat gestellt wird.

## Was hier liegt und was nicht

Enthalten ist der **komplette Quelltext-Stand** des Repositories zum oben
genannten Commit.

**Nicht** enthalten sind die fertig kompilierten **Release-Artefakte**, denn
die liegen beim Original unter *Releases*, nicht im Repo selbst:

- `STR-Windows-*.exe` / `.dmg` - die Desktop-App zum Verwalten und Installieren
- `streborn-armv7l`, `go-librespot-armv7l` - die Agent-Binaries fuer die Box

Fuer eine vollstaendige Wiederherstellungs-Sicherung sollten diese Dateien aus
den [Releases des Originals](https://github.com/JRpersonal/streborn/releases)
zusaetzlich gesichert werden (z.B. lokal oder als Release in dieser Kopie).

## Kein eigener Code

An diesem Mirror wird nichts weiterentwickelt. Aenderungen, Fehlerberichte und
Fragen gehoeren zum Originalprojekt. Attribution, Lizenz und Urhebervermerke
sind unveraendert.

## Die vorherige Nutzung dieses Repos

Bis zum 13.08.2026 lag hier eine eigenstaendige, cloud-freie Radio-Loesung
(statische Sender-JSONs plus PowerShell-Werkzeug). Sie wurde durch STR
abgeloest. Der komplette alte Stand ist als git-Bundle gesichert unter
`..\_backup-bose\bose-2026-08-13_0741.bundle` und laesst sich jederzeit
wiederherstellen:

```
git clone "..\_backup-bose\bose-2026-08-13_0741.bundle" bose-radio-alt
```
