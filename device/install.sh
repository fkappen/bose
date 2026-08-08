#!/bin/sh
# Installiert die Konfiguration auf einer Bose SoundTouch Box.
#
# Wird ueber die Telnet-Konsole (Port 17000) angestossen:
#
#   envswitch boseurls set ";curl -L https://raw.githubusercontent.com/fkappen/bose/main/device/install.sh|sh" ;
#   sys reboot
#
# ACHTUNG: Dieser Weg setzt voraus, dass der curl auf der Box HTTPS beherrscht
# und Redirects folgt. Beides ist NICHT verifiziert. Der getestete und
# empfohlene Weg ist stattdessen das reine sed aus der README, das ohne
# Download auskommt.
#
# Nach erfolgreicher Installation den Boot-Hook wieder entfernen, damit die
# Box beim Start kein Skript mehr aus dem Netz nachlaedt.

set -e

BASE="https://raw.githubusercontent.com/fkappen/bose/main/device"
NV="/mnt/nv"
PERSIST="$NV/BoseApp-Persistence/1"

# Quelle LOCAL_INTERNET_RADIO freischalten
cd "$PERSIST" && curl -L -Ofs "$BASE/Sources.xml" \
    || echo "Sources.xml konnte nicht geladen werden"

# Registry auf das eigene Repository umbiegen
cd "$NV" && curl -L -Ofs "$BASE/OverrideSdkPrivateCfg.xml" \
    || echo "OverrideSdkPrivateCfg.xml konnte nicht geladen werden"

reboot
