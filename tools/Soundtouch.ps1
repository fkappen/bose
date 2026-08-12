#Version
$version = "2.1.0"
$datum = "2026-08-09"
$autor = "Felix Kappen"

<#
.SYNOPSIS
    Verwaltung und Einrichtung von Bose SoundTouch Geraeten.

.DESCRIPTION
    Menuegefuehrtes Werkzeug. Direkt aufgerufen startet das Menue:

        .\Soundtouch.ps1

    Wird das Skript dot-gesourct, stehen nur die Funktionen bereit und das
    Menue startet nicht:

        . .\Soundtouch.ps1
        Get-SoundtouchInfo -IPAddress 192.0.2.10
        Start-SoundtouchManager      # Menue bei Bedarf von Hand starten

    Hintergruende, API-Details und Verifikationsstand: siehe KNOWLEDGE.md

.NOTES
    PowerShell 5.1 kompatibel.
    Bewusst ohne param()-Block: PowerShell verlangt param() als allererste
    Anweisung, was mit dem Versionsheader oben kollidiert.
#>

Set-StrictMode -Version Latest

# ===================================================================
#  Konfiguration
# ===================================================================

# Basis-URL der Senderdateien.
# GitHub Pages waere die Alternative, benoetigt aber eine .nojekyll-Datei:
#   https://fkappen.github.io/bose/stations
$script:StationBaseUrl   = "https://raw.githubusercontent.com/fkappen/bose/main/stations"
$script:RegistryUrl      = "https://raw.githubusercontent.com/fkappen/bose/main/registry.json"
$script:RadioBrowserBase = "https://all.api.radio-browser.info"
$script:UserAgent        = "soundtouch-tools/$version"

$script:RepoRoot   = Split-Path -Parent $PSScriptRoot
$script:StationDir = Join-Path $script:RepoRoot "stations"
$script:IndexPath  = Join-Path $script:StationDir "index.json"
$script:PresetPath = Join-Path $script:RepoRoot "presets.json"

# Aktuell im Menue gewaehltes Geraet
$script:Device = $null

# ===================================================================
#  Interne Helfer
# ===================================================================

function Invoke-StRequest {
    <#
        HTTP-Helfer. Gibt den Body als String zurueck.
        Invoke-WebRequest liefert je nach Content-Type ein Byte-Array,
        deshalb wird explizit dekodiert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = "GET",
        [string]$Body,
        [string]$ContentType = "application/xml",
        [int]$TimeoutSec = 20
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $params = @{
        Uri             = $Uri
        Method          = $Method
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
        UserAgent       = $script:UserAgent
    }
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        # Als UTF-8 Bytes senden, sonst werden Umlaute verstuemmelt
        $params["Body"] = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params["ContentType"] = "$ContentType; charset=utf-8"
    }

    $response = Invoke-WebRequest @params
    if ($null -eq $response) { return "" }
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    return [string]$response.Content
}

function Write-JsonFile {
    <#
        Schreibt JSON ohne BOM. PowerShell setzt sonst ein UTF-8-BOM davor,
        an dem manche Parser scheitern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $json = $Object | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-Slug {
    <#
        Erzeugt aus einem Sendernamen einen dateisystem- und URL-tauglichen
        Bezeichner. Deutsche Umlaute werden ausgeschrieben, nicht entfernt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $s = $Text.ToLowerInvariant()

    # Beide Argumente muessen Strings sein - String.Replace hat keine
    # Ueberladung (char, string).
    $s = $s.Replace([string][char]0x00E4, "ae")   # ae
    $s = $s.Replace([string][char]0x00F6, "oe")   # oe
    $s = $s.Replace([string][char]0x00FC, "ue")   # ue
    $s = $s.Replace([string][char]0x00DF, "ss")   # ss

    # Verbleibende Diakritika entfernen (e mit Akzent, o mit Schraegstrich usw.)
    $norm = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    $s = $sb.ToString()

    $s = [Text.RegularExpressions.Regex]::Replace($s, "[^a-z0-9]+", "-")
    $s = $s.Trim("-")
    $s = [Text.RegularExpressions.Regex]::Replace($s, "-{2,}", "-")

    if ($s.Length -gt 48) { $s = $s.Substring(0, 48).Trim("-") }
    return $s
}

function New-BmxObject {
    <#
        Baut das JSON-Objekt, das die Box erwartet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$StreamUrl,
        [string]$ImageUrl = "",
        [bool]$IsRealtime = $true,
        [bool]$HasPlaylist = $true
    )

    return [ordered]@{
        name       = $Name
        streamType = "liveRadio"
        imageUrl   = $ImageUrl
        audio      = [ordered]@{
            isRealtime  = $IsRealtime
            hasPlaylist = $HasPlaylist
            streamUrl   = $StreamUrl
            streams     = @(
                [ordered]@{
                    isRealtime  = $IsRealtime
                    hasPlaylist = $HasPlaylist
                    streamUrl   = $StreamUrl
                }
            )
        }
    }
}

function Get-StationIndex {
    <#
        Liest stations/index.json. Gibt eine leere Hashtable zurueck,
        wenn die Datei fehlt.
    #>
    [CmdletBinding()]
    param()

    $result = @{}
    if (-not (Test-Path $script:IndexPath)) { return $result }

    try {
        $raw = Get-Content $script:IndexPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }

        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj -or $obj.PSObject.Properties.Match("stations").Count -eq 0) { return $result }

        foreach ($p in $obj.stations.PSObject.Properties) {
            $result[$p.Name] = $p.Value
        }
    }
    catch {
        Write-Warning "index.json konnte nicht gelesen werden: $_"
    }
    return $result
}

function Save-StationIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index
    )

    $ordered = [ordered]@{}
    foreach ($k in ($Index.Keys | Sort-Object)) { $ordered[$k] = $Index[$k] }

    Write-JsonFile -Path $script:IndexPath -Object ([ordered]@{
        _hinweis = "Katalog der lokalen Senderdateien. Wird von Update-StationCatalog gepflegt."
        aktualisiert = (Get-Date -Format "yyyy-MM-dd")
        anzahl   = $ordered.Count
        stations = $ordered
    })
}

# ===================================================================
#  Geraete
# ===================================================================

function Get-SoundtouchInfo {
    <#
    .SYNOPSIS
        Liest /info und prueft die Firmware-Version.
    .EXAMPLE
        Get-SoundtouchInfo -IPAddress 192.0.2.10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress
    )

    try {
        $raw = Invoke-StRequest -Uri ("http://{0}:8090/info" -f $IPAddress) -TimeoutSec 10
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Error "Leere Antwort von $IPAddress"
            return
        }

        $doc = [xml]$raw
        $info = $doc.SelectSingleNode("/info")
        if ($null -eq $info) {
            Write-Error "Unerwartete Antwort von $IPAddress"
            return
        }

        # SelectNodes statt Punktzugriff, damit fehlende Knoten unter
        # Set-StrictMode nicht zum Abbruch fuehren.
        $komponenten = @($doc.SelectNodes("/info/components/component"))
        $firmware = ""
        foreach ($c in $komponenten) {
            $n = $c.SelectSingleNode("componentCategory")
            if ($null -ne $n -and $n.InnerText -eq "PackagedProduct") {
                $v = $c.SelectSingleNode("softwareVersion")
                if ($null -ne $v) { $firmware = [string]$v.InnerText }
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($firmware)) {
            foreach ($c in $komponenten) {
                $v = $c.SelectSingleNode("softwareVersion")
                if ($null -ne $v) { $firmware = [string]$v.InnerText; break }
            }
        }

        # Major-Version defensiv ermitteln, nicht blind casten
        $major = -1
        if (-not [string]::IsNullOrWhiteSpace($firmware)) {
            $parsed = 0
            if ([int]::TryParse((($firmware -split '\.')[0]), [ref]$parsed)) { $major = $parsed }
        }

        # Kindknoten einzeln lesen. Punktzugriff waere hier doppelt heikel:
        # fehlende Knoten brechen unter StrictMode ab, und '.name' kollidiert
        # mit der eingebauten Eigenschaft XmlNode.Name.
        function Get-Text {
            param($Knoten, [string]$Pfad)
            $n = $Knoten.SelectSingleNode($Pfad)
            if ($null -eq $n) { return "" }
            return [string]$n.InnerText
        }

        [PSCustomObject]@{
            IPAddress     = $IPAddress
            Name          = (Get-Text $info "name")
            Type          = (Get-Text $info "type")
            DeviceID      = [string]$info.GetAttribute("deviceID")
            Variant       = (Get-Text $info "variant")
            ModuleType    = (Get-Text $info "moduleType")
            Firmware      = $firmware
            FirmwareMajor = $major
            Supported     = ($major -ge 27)
        }
    }
    catch {
        Write-Error $_
    }
}

function Find-Soundtouch {
    <#
    .SYNOPSIS
        Sucht SoundTouch-Boxen im Netz (offener Port 8090).
    .DESCRIPTION
        mDNS funktioniert nicht ueber VLAN-Grenzen, deshalb wird per
        TCP-Connect gescannt. Ohne -Subnet werden alle lokalen IPv4-Netze
        des Rechners durchsucht.
    .EXAMPLE
        Find-Soundtouch -Subnet "192.0.2"
    #>
    [CmdletBinding()]
    param(
        [string[]]$Subnet,
        [int]$TimeoutMs = 2500
    )

    try {
        if ($null -eq $Subnet -or $Subnet.Count -eq 0) {
            $Subnet = @()
            foreach ($a in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                if ($a.IPAddress -like "127.*" -or $a.IPAddress -like "169.254.*") { continue }
                $parts = $a.IPAddress -split '\.'
                if ($parts.Count -eq 4) { $Subnet += ("{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2]) }
            }
            $Subnet = @($Subnet | Select-Object -Unique)
            if ($Subnet.Count -eq 0) {
                Write-Error "Kein lokales IPv4-Netz gefunden. -Subnet angeben."
                return
            }
        }

        $found = @()
        foreach ($net in $Subnet) {
            if ($net -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                Write-Warning "Ungueltiges Subnetz '$net' - uebersprungen (erwartet: '192.0.2')."
                continue
            }

            Write-Verbose "Scanne $net.0/24"
            $pending = @()
            foreach ($i in 1..254) {
                $ip = "$net.$i"
                $client = New-Object System.Net.Sockets.TcpClient
                $pending += [PSCustomObject]@{
                    IP     = $ip
                    Client = $client
                    Async  = $client.BeginConnect($ip, 8090, $null, $null)
                }
            }

            Start-Sleep -Milliseconds $TimeoutMs

            foreach ($p in $pending) {
                if ($p.Async.IsCompleted -and $p.Client.Connected) { $found += $p.IP }
                try { $p.Client.Close() } catch { Write-Verbose $_ }
            }
        }

        foreach ($ip in $found) {
            $info = Get-SoundtouchInfo -IPAddress $ip
            if ($null -ne $info) { $info }
        }
    }
    catch {
        Write-Error $_
    }
}

function Get-SoundtouchPreset {
    <#
    .SYNOPSIS
        Liest die Belegung der Preset-Tasten 1-6.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress
    )

    try {
        $raw = Invoke-StRequest -Uri ("http://{0}:8090/presets" -f $IPAddress)
        if ([string]::IsNullOrWhiteSpace($raw)) { return }

        # SelectNodes statt Punktzugriff: Bei einer Box ohne Presets gibt es
        # den Knoten 'preset' gar nicht, und Set-StrictMode laesst
        # $xml.presets.preset dann scheitern.
        $xml = [xml]$raw
        foreach ($p in @($xml.SelectNodes("/presets/preset"))) {
            if ($null -eq $p) { continue }

            $itemName = ""; $source = ""; $location = ""; $art = ""
            $ci = $p.SelectSingleNode("ContentItem")
            if ($null -ne $ci) {
                $source   = [string]$ci.GetAttribute("source")
                $location = [string]$ci.GetAttribute("location")

                $n = $ci.SelectSingleNode("itemName")
                if ($null -ne $n) { $itemName = [string]$n.InnerText }

                $a = $ci.SelectSingleNode("containerArt")
                if ($null -ne $a) { $art = [string]$a.InnerText }
            }

            [PSCustomObject]@{
                Preset   = [string]$p.GetAttribute("id")
                Name     = $itemName
                Source   = $source
                Location = $location
                Art      = $art
                IsOwn    = ($location -like "$script:StationBaseUrl/*")
            }
        }
    }
    catch {
        Write-Error $_
    }
}

function Set-SoundtouchPreset {
    <#
    .SYNOPSIS
        Legt eine Senderdatei aus diesem Repo auf eine Preset-Taste.
    .DESCRIPTION
        Prueft vor dem Schreiben, ob die Datei im Repo abrufbar ist, damit
        kein totes Preset auf der Taste landet.
    .EXAMPLE
        Set-SoundtouchPreset -IPAddress 192.0.2.10 -Preset 1 -Slug "swr4-koblenz"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][ValidateRange(1, 6)][int]$Preset,
        [Parameter(Mandatory = $true)][string]$Slug,
        [switch]$SkipCheck
    )

    try {
        $location = "$script:StationBaseUrl/$Slug.json"
        $name = $Slug
        $art  = ""

        if (-not $SkipCheck) {
            try {
                $check = Invoke-StRequest -Uri $location -TimeoutSec 25
            }
            catch {
                Write-Error "Senderdatei nicht abrufbar: $location - erst committen und pushen. ($_)"
                return
            }
            if ([string]::IsNullOrWhiteSpace($check)) {
                Write-Error "Senderdatei leer: $location"
                return
            }

            $parsed = $check | ConvertFrom-Json
            if ($parsed.PSObject.Properties.Match("name").Count -gt 0) { $name = [string]$parsed.name }
            if ($parsed.PSObject.Properties.Match("imageUrl").Count -gt 0 -and $null -ne $parsed.imageUrl) {
                $art = [string]$parsed.imageUrl
            }
        }

        $xmlBody = @"
<preset id="$Preset">
    <ContentItem source="LOCAL_INTERNET_RADIO" type="stationurl" location="$([Security.SecurityElement]::Escape($location))" isPresetable="true">
        <itemName>$([Security.SecurityElement]::Escape($name))</itemName>
        <containerArt>$([Security.SecurityElement]::Escape($art))</containerArt>
    </ContentItem>
</preset>
"@

        $result = Invoke-StRequest -Uri ("http://{0}:8090/storePreset" -f $IPAddress) `
            -Method "POST" -Body $xmlBody -ContentType "application/xml"

        [PSCustomObject]@{
            Preset   = $Preset
            Name     = $name
            Slug     = $Slug
            Location = $location
            Response = $result
        }
    }
    catch {
        Write-Error $_
    }
}

function Set-SoundtouchPresetSet {
    <#
    .SYNOPSIS
        Wendet ein Profil aus presets.json auf eine Box an.
    .EXAMPLE
        Set-SoundtouchPresetSet -IPAddress 192.0.2.10 -ProfileName "standard"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$ProfileName = "standard"
    )

    try {
        if (-not (Test-Path $script:PresetPath)) {
            Write-Error "presets.json nicht gefunden: $script:PresetPath"
            return
        }

        $map = (Get-Content $script:PresetPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($map.PSObject.Properties.Match("profile").Count -eq 0 -or
            $map.profile.PSObject.Properties.Match($ProfileName).Count -eq 0) {
            Write-Error "Profil '$ProfileName' existiert nicht in presets.json."
            return
        }

        foreach ($prop in $map.profile.$ProfileName.PSObject.Properties) {
            $slot = 0
            if (-not [int]::TryParse($prop.Name, [ref]$slot)) {
                Write-Warning "Ungueltige Tastennummer '$($prop.Name)' - uebersprungen."
                continue
            }
            Set-SoundtouchPreset -IPAddress $IPAddress -Preset $slot -Slug ([string]$prop.Value)
            Start-Sleep -Milliseconds 600
        }
    }
    catch {
        Write-Error $_
    }
}

function Test-SoundtouchSetup {
    <#
    .SYNOPSIS
        Gesamtpruefung einer Box.
    .EXAMPLE
        Test-SoundtouchSetup -IPAddress 192.0.2.10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress
    )

    $results = @()
    try {
        $info = Get-SoundtouchInfo -IPAddress $IPAddress
        if ($null -eq $info) { Write-Error "Box $IPAddress nicht erreichbar."; return }

        $results += [PSCustomObject]@{ Pruefung = "Erreichbar"; Ergebnis = "OK"; Detail = "$($info.Name) / $($info.DeviceID)" }
        $results += [PSCustomObject]@{
            Pruefung = "Firmware >= 27"
            Ergebnis = $(if ($info.Supported) { "OK" } else { "FEHLER" })
            Detail   = $info.Firmware
        }

        $srcRaw = Invoke-StRequest -Uri ("http://{0}:8090/sources" -f $IPAddress)
        $lirState = "fehlt"
        foreach ($s in @(([xml]$srcRaw).SelectNodes("/sources/sourceItem"))) {
            if ($null -ne $s -and $s.GetAttribute("source") -eq "LOCAL_INTERNET_RADIO") {
                $lirState = [string]$s.GetAttribute("status")
                break
            }
        }
        $results += [PSCustomObject]@{
            Pruefung = "Quelle LOCAL_INTERNET_RADIO"
            Ergebnis = $(if ($lirState -eq "READY") { "OK" } else { "FEHLER" })
            Detail   = $lirState
        }

        $presets = @(Get-SoundtouchPreset -IPAddress $IPAddress)
        $own     = @($presets | Where-Object { $_.IsOwn })
        $foreign = @($presets | Where-Object { -not $_.IsOwn })

        $results += [PSCustomObject]@{
            Pruefung = "Presets auf eigenem Repo"
            Ergebnis = $(if ($foreign.Count -eq 0 -and $own.Count -gt 0) { "OK" } else { "HINWEIS" })
            Detail   = ("{0} eigen, {1} fremd" -f $own.Count, $foreign.Count)
        }

        if ($own.Count -eq 0) {
            $results += [PSCustomObject]@{
                Pruefung = "Senderdateien abrufbar"
                Ergebnis = "HINWEIS"
                Detail   = "nicht geprueft, kein Preset zeigt auf dieses Repo"
            }
        }
        else {
            $bad = 0
            foreach ($p in $own) {
                try {
                    $body = Invoke-StRequest -Uri $p.Location -TimeoutSec 20
                    if ([string]::IsNullOrWhiteSpace($body)) { $bad++ }
                }
                catch { Write-Verbose $_; $bad++ }
            }
            $results += [PSCustomObject]@{
                Pruefung = "Senderdateien abrufbar"
                Ergebnis = $(if ($bad -eq 0) { "OK" } else { "FEHLER" })
                Detail   = ("{0} von {1} nicht erreichbar" -f $bad, $own.Count)
            }
        }

        $results
    }
    catch {
        Write-Error $_
    }
}

# ===================================================================
#  Telnet / Installation
# ===================================================================

function Invoke-BoseTelnet {
    <#
        Sendet Befehle an die Konsole auf Port 17000 und gibt die Ausgabe zurueck.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [int]$WaitSeconds = 4
    )

    $client = $null
    $stream = $null
    $log = New-Object System.Text.StringBuilder

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($IPAddress, 17000, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000) -or -not $client.Connected) {
            Write-Error "Port 17000 auf $IPAddress nicht erreichbar."
            return
        }
        $client.EndConnect($async)

        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true
        $buf = New-Object byte[] 16384

        Start-Sleep -Milliseconds 800

        foreach ($cmd in $Commands) {
            [void]$log.AppendLine("> $cmd")
            $writer.WriteLine($cmd)

            $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -gt 0) { [void]$log.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
                }
                else { Start-Sleep -Milliseconds 200 }
            }
        }

        return $log.ToString()
    }
    catch {
        Write-Error $_
    }
    finally {
        if ($null -ne $stream) { try { $stream.Close() } catch { Write-Verbose $_ } }
        if ($null -ne $client) { try { $client.Close() } catch { Write-Verbose $_ } }
    }
}

function Install-BoseRadio {
    <#
    .SYNOPSIS
        Biegt bmxRegistryUrl auf dieses Repository um (Telnet, Port 17000).

    .DESCRIPTION
        ACHTUNG - dauerhafter Eingriff, die Box startet neu.

        Laedt bewusst KEIN Skript nach, sondern aendert per sed nur die
        vorhandene Konfigurationsdatei. Voraussetzung ist, dass
        /mnt/nv/OverrideSdkPrivateCfg.xml bereits existiert. Bei einer
        fabrikfrischen Box ist das nicht der Fall - siehe ROLLOUT.md.

        Ohne -Confirm wird nichts gesendet.

    .EXAMPLE
        Install-BoseRadio -IPAddress 192.0.2.10 -Confirm
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [string]$OldUrl = "http://soundploy.gmuth.de/v2/registry.json",
        [string]$NewUrl = "",
        [switch]$Confirm
    )

    if ([string]::IsNullOrWhiteSpace($NewUrl)) { $NewUrl = $script:RegistryUrl }

    # '#' als sed-Trenner, damit die Schraegstriche der URLs nicht stoeren
    $sed = "sed -i s#{0}#{1}#g /mnt/nv/OverrideSdkPrivateCfg.xml" -f $OldUrl, $NewUrl
    $commands = @(
        ('envswitch boseurls set ";{0}" ";{0}"' -f $sed)
        'sys reboot'
    )

    if (-not $Confirm) {
        Write-Warning "Abbruch: Install-BoseRadio wurde ohne -Confirm aufgerufen."
        Write-Output "Es wuerden folgende Befehle an ${IPAddress}:17000 gesendet:"
        $commands | ForEach-Object { Write-Output "  $_" }
        return
    }

    $out = Invoke-BoseTelnet -IPAddress $IPAddress -Commands $commands
    Write-Output $out
    Write-Output ""
    Write-Output "Befehle gesendet. Die Box startet neu (ca. 1-3 Minuten)."
}

function Install-BoseRadioFactory {
    <#
    .SYNOPSIS
        Bereitet eine fabrikfrische Box vor (Stufe 1 von 2).

    .DESCRIPTION
        Auf einer unberuehrten Box fehlen sowohl Sources.xml als auch
        OverrideSdkPrivateCfg.xml. Ein sed laeuft dort ins Leere, die Dateien
        muessen erst angelegt werden.

        Diese Funktion stoesst dafuer einmalig den Installer von SoundPloy an.
        Der arbeitet ueber einfaches HTTP und ist auf dieser Hardware
        erprobt - im Gegensatz zum eigenen install.sh, das HTTPS auf der Box
        voraussetzt, was nicht verifiziert ist.

        Das bedeutet: Die Box vertraut dem fremden Server soundploy.gmuth.de
        fuer genau einen Bootvorgang. Danach uebernimmt Install-BoseRadio und
        biegt die Registry auf das eigene Repository um.

        ACHTUNG - zwei Nebenwirkungen:
          - Eine vorhandene Spotify-Verknuepfung geht dabei verloren und
            laesst sich voraussichtlich nicht wiederherstellen.
          - Bose-Firmwareupdates werden deaktiviert.

        Ohne -Confirm wird nichts gesendet.

    .EXAMPLE
        Install-BoseRadioFactory -IPAddress 192.0.2.10 -Confirm
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [switch]$Confirm
    )

    $commands = @(
        'envswitch boseurls set ";curl soundploy.gmuth.de/v2_install|sh" ;'
        'sys reboot'
    )

    if (-not $Confirm) {
        Write-Warning "Abbruch: Install-BoseRadioFactory wurde ohne -Confirm aufgerufen."
        Write-Output "Es wuerden folgende Befehle an ${IPAddress}:17000 gesendet:"
        $commands | ForEach-Object { Write-Output "  $_" }
        return
    }

    $out = Invoke-BoseTelnet -IPAddress $IPAddress -Commands $commands
    Write-Output $out
    Write-Output ""
    Write-Output "Befehle gesendet. Die Box startet nun zweimal neu (2-3 Minuten)."
}

function Reset-BoseBootHook {
    <#
    .SYNOPSIS
        Entschaerft den Boot-Hook in 'boseurls'.
    .DESCRIPTION
        Setzt beide Felder auf ';true', also einen Befehl ohne Wirkung.

        UNGEPRUEFT: Der Werkszustand dieser Variable ist nicht bekannt und
        laesst sich nicht auslesen. ';true' ist ein bewusst harmloser
        Platzhalter, kein Werksreset.

        Ohne -Confirm wird nichts gesendet.
    .EXAMPLE
        Reset-BoseBootHook -IPAddress 192.0.2.10 -Confirm
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [switch]$Confirm
    )

    $commands = @('envswitch boseurls set ";true" ";true"')

    if (-not $Confirm) {
        Write-Warning "Abbruch: Reset-BoseBootHook wurde ohne -Confirm aufgerufen."
        Write-Output "Es wuerde gesendet: $($commands[0])"
        return
    }

    Write-Output (Invoke-BoseTelnet -IPAddress $IPAddress -Commands $commands)
}

function Wait-Soundtouch {
    <#
    .SYNOPSIS
        Wartet, bis eine Box nach einem Neustart wieder antwortet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [int]$TimeoutMinutes = 6
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $wasDown = $false

    while ((Get-Date) -lt $deadline) {
        $up = $false
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $a = $c.BeginConnect($IPAddress, 8090, $null, $null)
            if ($a.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) { $up = $true }
        }
        catch { $up = $false }
        finally { try { $c.Close() } catch { Write-Verbose $_ } }

        if (-not $up) {
            $wasDown = $true
            Write-Host ("  {0}  offline (Neustart laeuft)" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("  {0}  online" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor Green
            if ($wasDown) {
                Start-Sleep -Seconds 20
                return $true
            }
        }
        Start-Sleep -Seconds 10
    }

    Write-Warning "Zeitueberschreitung: Box kam nicht zurueck."
    return $false
}

# ===================================================================
#  Sender
# ===================================================================

function Find-RadioStation {
    <#
    .SYNOPSIS
        Sucht Sender bei radio-browser.info.
    .EXAMPLE
        Find-RadioStation -Name "Antenne Bayern"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Limit = 10
    )

    try {
        $uri = "{0}/json/stations/byname/{1}?limit={2}&order=clickcount&reverse=true&hidebroken=true" -f `
            $script:RadioBrowserBase, [uri]::EscapeDataString($Name), $Limit

        $raw = Invoke-StRequest -Uri $uri -TimeoutSec 30
        if ([string]::IsNullOrWhiteSpace($raw)) { return }

        # PS 5.1: ConvertFrom-Json reicht ein Array als EIN Objekt durch die
        # Pipeline. @($x | ConvertFrom-Json) ergibt darum immer 1 - erst
        # zuweisen, dann umschliessen.
        $parsed = $raw | ConvertFrom-Json

        foreach ($s in @($parsed)) {
            if ($null -eq $s) { continue }

            $favicon = ""
            if ($s.PSObject.Properties.Match("favicon").Count -gt 0 -and $null -ne $s.favicon) { $favicon = [string]$s.favicon }
            $country = ""
            if ($s.PSObject.Properties.Match("country").Count -gt 0 -and $null -ne $s.country) { $country = [string]$s.country }
            $votes = 0
            if ($s.PSObject.Properties.Match("votes").Count -gt 0 -and $null -ne $s.votes) { $votes = [int]$s.votes }

            # 'url' ist die stabile Einstiegs-URL. 'url_resolved' kann eine
            # befristete, tokenisierte Adresse sein - die ist unbrauchbar.
            [PSCustomObject]@{
                Name        = ([string]$s.name).Trim()
                StationUuid = [string]$s.stationuuid
                Country     = $country
                StreamUrl   = [string]$s.url
                Favicon     = $favicon
                Votes       = $votes
            }
        }
    }
    catch {
        Write-Error $_
    }
}

function New-StationFile {
    <#
    .SYNOPSIS
        Legt stations/<Slug>.json an.
    .DESCRIPTION
        Nimmt entweder direkte Werte oder einen Treffer aus Find-RadioStation
        aus der Pipeline. Danach committen und pushen, sonst findet die Box
        die Datei nicht.
    .EXAMPLE
        Find-RadioStation -Name "Antenne Bayern" | Select-Object -First 1 |
            New-StationFile
    #>
    [CmdletBinding()]
    param(
        [string]$Slug,
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$Name,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$StreamUrl,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$StationUuid,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Favicon = "",
        [switch]$Force
    )

    process {
        try {
            $useSlug = $Slug
            if ([string]::IsNullOrWhiteSpace($useSlug)) { $useSlug = ConvertTo-Slug -Text $Name }
            if ([string]::IsNullOrWhiteSpace($useSlug)) {
                Write-Error "Aus '$Name' liess sich kein Slug bilden."
                return
            }

            $url = $StreamUrl
            if ([string]::IsNullOrWhiteSpace($url)) {
                if ([string]::IsNullOrWhiteSpace($StationUuid)) {
                    Write-Error "Weder StreamUrl noch StationUuid angegeben."
                    return
                }
                $raw = Invoke-StRequest -Uri "$script:RadioBrowserBase/soundtouch/stations/byuuid/$StationUuid" -TimeoutSec 30
                $bmx = $raw | ConvertFrom-Json
                $url = [string]$bmx.audio.streamUrl
            }
            if ([string]::IsNullOrWhiteSpace($url)) {
                Write-Error "Keine Stream-URL fuer '$Name' ermittelbar."
                return
            }

            $path = Join-Path $script:StationDir "$useSlug.json"
            if ((Test-Path $path) -and -not $Force) {
                Write-Verbose "Existiert bereits, uebersprungen: $useSlug"
                [PSCustomObject]@{ Slug = $useSlug; Name = $Name; StreamUrl = $url; Path = $path; Status = "vorhanden" }
                return
            }

            Write-JsonFile -Path $path -Object (New-BmxObject -Name $Name -StreamUrl $url -ImageUrl $Favicon)

            $idx = Get-StationIndex
            $idx[$useSlug] = [ordered]@{
                name = $Name
                uuid = $StationUuid
                url  = $url
            }
            Save-StationIndex -Index $idx

            [PSCustomObject]@{ Slug = $useSlug; Name = $Name; StreamUrl = $url; Path = $path; Status = "angelegt" }
        }
        catch {
            Write-Error $_
        }
    }
}

function Update-StationCatalog {
    <#
    .SYNOPSIS
        Holt die beliebtesten Sender eines Landes und legt sie als Dateien ab.
    .DESCRIPTION
        Ein einziger Abruf bei radio-browser, sortiert nach Klickzahl. Es wird
        das Feld 'url' verwendet, nicht 'url_resolved' - letzteres kann eine
        befristete, tokenisierte Adresse sein.

        Bestehende Dateien werden aktualisiert, sofern sich die Stream-URL
        geaendert hat. Handgepflegte Sender, die nicht in der Liste stehen,
        bleiben unberuehrt.
    .EXAMPLE
        Update-StationCatalog -Top 100 -CountryCode DE
    #>
    [CmdletBinding()]
    param(
        [int]$Top = 100,
        [string]$CountryCode = "DE",
        [switch]$WhatIfOnly
    )

    try {
        # Puffer holen, weil Duplikate und unbrauchbare Eintraege wegfallen
        $fetch = [Math]::Min(($Top * 3), 600)
        $uri = "{0}/json/stations/search?countrycode={1}&order=clickcount&reverse=true&limit={2}&hidebroken=true" -f `
            $script:RadioBrowserBase, [uri]::EscapeDataString($CountryCode), $fetch

        Write-Host "Rufe Senderliste ab ($CountryCode, Top $Top)..." -ForegroundColor Cyan
        $raw = Invoke-StRequest -Uri $uri -TimeoutSec 90
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Error "radio-browser lieferte keine Daten."
            return
        }

        # PS 5.1: erst zuweisen, dann @() - sonst kommt immer 1 heraus.
        $parsed = $raw | ConvertFrom-Json
        $all = @($parsed)

        if ($all.Count -lt 2) {
            Write-Error "Unerwartet wenige Eintraege ($($all.Count)) - Abbruch, um den Katalog nicht zu beschaedigen."
            return
        }
        Write-Host ("{0} Eintraege erhalten, verarbeite..." -f $all.Count) -ForegroundColor DarkGray

        $idx = Get-StationIndex
        $usedSlugs = @{}
        $stats = [ordered]@{ Neu = 0; Aktualisiert = 0; Unveraendert = 0; Uebersprungen = 0 }
        $taken = 0
        $report = @()

        foreach ($s in $all) {
            if ($taken -ge $Top) { break }
            if ($null -eq $s) { continue }

            $name = ([string]$s.name).Trim()
            $url  = [string]$s.url
            if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($url)) {
                $stats.Uebersprungen++
                continue
            }

            $slug = ConvertTo-Slug -Text $name
            if ([string]::IsNullOrWhiteSpace($slug)) { $stats.Uebersprungen++; continue }

            # Doppelte Namen innerhalb eines Laufs auseinanderhalten
            if ($usedSlugs.ContainsKey($slug)) { $stats.Uebersprungen++; continue }
            $usedSlugs[$slug] = $true

            $favicon = ""
            if ($s.PSObject.Properties.Match("favicon").Count -gt 0 -and $null -ne $s.favicon) { $favicon = [string]$s.favicon }
            $uuid = [string]$s.stationuuid

            $path = Join-Path $script:StationDir "$slug.json"
            $zustand = "Neu"

            if (Test-Path $path) {
                $alt = (Get-Content $path -Raw -Encoding UTF8) | ConvertFrom-Json
                if ([string]$alt.audio.streamUrl -eq $url) { $zustand = "Unveraendert" }
                else { $zustand = "Aktualisiert" }
            }

            if (-not $WhatIfOnly -and $zustand -ne "Unveraendert") {
                Write-JsonFile -Path $path -Object (New-BmxObject -Name $name -StreamUrl $url -ImageUrl $favicon)
            }

            $idx[$slug] = [ordered]@{ name = $name; uuid = $uuid; url = $url }
            $stats[$zustand]++
            $taken++

            $report += [PSCustomObject]@{ Slug = $slug; Name = $name; Zustand = $zustand }
        }

        if (-not $WhatIfOnly) { Save-StationIndex -Index $idx }

        Write-Host ""
        Write-Host ("Fertig: {0} Sender im Katalog" -f $taken) -ForegroundColor Green
        Write-Host ("  neu {0}   aktualisiert {1}   unveraendert {2}   uebersprungen {3}" -f `
            $stats.Neu, $stats.Aktualisiert, $stats.Unveraendert, $stats.Uebersprungen) -ForegroundColor DarkGray
        if ($WhatIfOnly) { Write-Host "  (Trockenlauf - nichts geschrieben)" -ForegroundColor Yellow }
        else { Write-Host "  Nicht vergessen: committen und pushen." -ForegroundColor Yellow }

        $report
    }
    catch {
        Write-Error $_
    }
}

function Test-StationStream {
    <#
    .SYNOPSIS
        Prueft eine Stream-URL auf Erreichbarkeit.
    .DESCRIPTION
        Bewusst per Rohsocket statt per Invoke-WebRequest: Viele Radiostreams
        antworten mit "ICY 200 OK" statt "HTTP/1.1 200 OK". Die .NET-Klasse
        HttpWebRequest wertet das als Protokollverletzung und wirft, obwohl
        der Stream voellig in Ordnung ist. Hier wird die Statuszeile selbst
        gelesen, deshalb faellt kein funktionierender Sender durch.
    .EXAMPLE
        Test-StationStream -Url "http://streams.radiobob.de/bob-national/mp3-192/mediaplayer"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 8000,
        [int]$MaxRedirect = 3
    )

    $current = $Url
    for ($hop = 0; $hop -le $MaxRedirect; $hop++) {
        $tcp = $null
        $stream = $null
        try {
            $uri = [Uri]$current
            $isTls = ($uri.Scheme -eq "https")
            $port = $uri.Port
            if ($port -le 0) { if ($isTls) { $port = 443 } else { $port = 80 } }

            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($uri.Host, $port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs) -or -not $tcp.Connected) {
                return [PSCustomObject]@{ Ok = $false; Status = "keine Verbindung"; Url = $current }
            }
            $tcp.EndConnect($async)
            $tcp.ReceiveTimeout = $TimeoutMs
            $tcp.SendTimeout = $TimeoutMs

            $stream = $tcp.GetStream()
            if ($isTls) {
                # Standardvalidierung beibehalten - ein kaputtes Zertifikat
                # soll auffallen und nicht stillschweigend durchgehen.
                $ssl = New-Object System.Net.Security.SslStream($stream, $false)
                $ssl.AuthenticateAsClient($uri.Host)
                $stream = $ssl
            }

            $path = $uri.PathAndQuery
            if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }

            $req = "GET $path HTTP/1.1`r`n" +
                   "Host: $($uri.Host)`r`n" +
                   "User-Agent: SoundTouch`r`n" +
                   "Icy-MetaData: 1`r`n" +
                   "Accept: */*`r`n" +
                   "Connection: close`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($req)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()

            $buf = New-Object byte[] 2048
            $read = $stream.Read($buf, 0, $buf.Length)
            if ($read -le 0) {
                return [PSCustomObject]@{ Ok = $false; Status = "keine Antwort"; Url = $current }
            }

            $head = [Text.Encoding]::ASCII.GetString($buf, 0, $read)
            $firstLine = ($head -split "`r?`n")[0]

            # ICY 200 OK ist gueltig, auch wenn es kein HTTP ist
            if ($firstLine -match '^(ICY|HTTP/\d\.\d)\s+(\d{3})') {
                $code = [int]$Matches[2]

                if ($code -ge 300 -and $code -lt 400) {
                    $loc = ""
                    foreach ($line in ($head -split "`r?`n")) {
                        if ($line -match '^(?i)location:\s*(.+)$') { $loc = $Matches[1].Trim(); break }
                    }
                    if ([string]::IsNullOrWhiteSpace($loc)) {
                        return [PSCustomObject]@{ Ok = $false; Status = "Redirect ohne Ziel ($code)"; Url = $current }
                    }
                    $current = ([Uri]::new([Uri]$current, $loc)).AbsoluteUri
                    continue
                }

                if ($code -ge 200 -and $code -lt 300) {
                    return [PSCustomObject]@{ Ok = $true; Status = $firstLine.Trim(); Url = $current }
                }
                return [PSCustomObject]@{ Ok = $false; Status = $firstLine.Trim(); Url = $current }
            }

            return [PSCustomObject]@{ Ok = $false; Status = "unverstaendliche Antwort"; Url = $current }
        }
        catch {
            return [PSCustomObject]@{ Ok = $false; Status = $_.Exception.Message; Url = $current }
        }
        finally {
            if ($null -ne $stream) { try { $stream.Dispose() } catch { Write-Verbose $_ } }
            if ($null -ne $tcp) { try { $tcp.Close() } catch { Write-Verbose $_ } }
        }
    }

    return [PSCustomObject]@{ Ok = $false; Status = "zu viele Weiterleitungen"; Url = $current }
}

function Test-StationFiles {
    <#
    .SYNOPSIS
        Prueft alle lokalen Senderdateien auf erreichbare Streams.
    .EXAMPLE
        Test-StationFiles -FailedOnly
    #>
    [CmdletBinding()]
    param(
        [string]$Filter = "*",
        [switch]$FailedOnly
    )

    $files = @(Get-ChildItem -Path $script:StationDir -Filter "*.json" |
        Where-Object { $_.Name -ne "index.json" -and $_.BaseName -like $Filter } | Sort-Object Name)

    $i = 0
    foreach ($f in $files) {
        $i++
        Write-Progress -Activity "Pruefe Streams" -Status $f.BaseName -PercentComplete (($i / [Math]::Max($files.Count,1)) * 100)

        try {
            $o = (Get-Content $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json
            $res = Test-StationStream -Url ([string]$o.audio.streamUrl)

            if ($FailedOnly -and $res.Ok) { continue }

            [PSCustomObject]@{
                Slug   = $f.BaseName
                Name   = [string]$o.name
                Ok     = $res.Ok
                Status = $res.Status
            }
        }
        catch {
            [PSCustomObject]@{ Slug = $f.BaseName; Name = ""; Ok = $false; Status = "Datei unlesbar: $_" }
        }
    }
    Write-Progress -Activity "Pruefe Streams" -Completed
}

function Convert-SoundtouchPreset {
    <#
    .SYNOPSIS
        Migriert die vorhandenen Presets einer Box auf dieses Repository.

    .DESCRIPTION
        Liest die aktuelle Belegung und sorgt dafuer, dass es fuer jeden
        Sender eine lokale Datei gibt:

          - Presets, die schon auf dieses Repo zeigen, bleiben unangetastet.
          - Zeigt ein Preset auf radio-browser, wird die UUID daraus gelesen.
          - Bei allen anderen (z.B. toten TuneIn-Presets) wird ueber den
            angezeigten Sendernamen gesucht und der beste Treffer genommen.

        Angelegt werden nur Dateien, die noch fehlen. Die Presets selbst
        werden NICHT geschrieben - die Dateien muessen erst auf GitHub
        liegen. Dafuer danach -Apply verwenden.

    .EXAMPLE
        Convert-SoundtouchPreset -IPAddress 192.0.2.10
        # committen und pushen, dann:
        Convert-SoundtouchPreset -IPAddress 192.0.2.10 -Apply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress,
        [switch]$Apply
    )

    try {
        $presets = @(Get-SoundtouchPreset -IPAddress $IPAddress)
        if ($presets.Count -eq 0) {
            Write-Warning "Keine Presets auf $IPAddress gefunden."
            return
        }

        $plan = @()

        foreach ($p in $presets) {
            if ($p.IsOwn) {
                $slug = [IO.Path]::GetFileNameWithoutExtension($p.Location)
                $plan += [PSCustomObject]@{
                    Preset = [int]$p.Preset; Name = $p.Name; Slug = $slug
                    Datei  = "vorhanden"; Herkunft = "bereits eigenes Repo"
                }
                continue
            }

            $slug = ConvertTo-Slug -Text $p.Name
            $uuid = ""
            $herkunft = "Namenssuche"

            # Zeigt das Preset auf die radio-browser-Bruecke? Dann UUID direkt nehmen.
            $m = [Text.RegularExpressions.Regex]::Match($p.Location, "byuuid/([0-9a-fA-F\-]{36})")
            if ($m.Success) {
                $uuid = $m.Groups[1].Value
                $herkunft = "UUID aus Preset"
            }

            $path = Join-Path $script:StationDir "$slug.json"
            if (Test-Path $path) {
                $plan += [PSCustomObject]@{
                    Preset = [int]$p.Preset; Name = $p.Name; Slug = $slug
                    Datei  = "vorhanden"; Herkunft = $herkunft
                }
                continue
            }

            $created = $null
            if (-not [string]::IsNullOrWhiteSpace($uuid)) {
                $created = New-StationFile -Slug $slug -Name $p.Name -StationUuid $uuid -Favicon $p.Art
            }
            else {
                $hit = Find-RadioStation -Name $p.Name -Limit 1 | Select-Object -First 1
                if ($null -eq $hit) {
                    $plan += [PSCustomObject]@{
                        Preset = [int]$p.Preset; Name = $p.Name; Slug = ""
                        Datei  = "KEIN TREFFER"; Herkunft = $herkunft
                    }
                    continue
                }
                $created = New-StationFile -Slug $slug -Name $p.Name -StreamUrl $hit.StreamUrl `
                    -StationUuid $hit.StationUuid -Favicon $hit.Favicon
            }

            $status = "angelegt"
            if ($null -eq $created) { $status = "FEHLER" }

            $plan += [PSCustomObject]@{
                Preset = [int]$p.Preset; Name = $p.Name; Slug = $slug
                Datei  = $status; Herkunft = $herkunft
            }
        }

        if (-not $Apply) {
            Write-Host ""
            Write-Host "Neu angelegte Dateien muessen committet und gepusht werden," -ForegroundColor Yellow
            Write-Host "danach dieselbe Funktion mit -Apply aufrufen." -ForegroundColor Yellow
            return $plan
        }

        Write-Host ""
        Write-Host "Setze Presets..." -ForegroundColor Cyan
        foreach ($e in $plan) {
            if ([string]::IsNullOrWhiteSpace($e.Slug) -or $e.Datei -eq "FEHLER") {
                Write-Warning ("Taste {0} uebersprungen ({1})" -f $e.Preset, $e.Datei)
                continue
            }
            Set-SoundtouchPreset -IPAddress $IPAddress -Preset $e.Preset -Slug $e.Slug
            Start-Sleep -Milliseconds 600
        }
        return $plan
    }
    catch {
        Write-Error $_
    }
}

# ===================================================================
#  Menue
# ===================================================================

function Write-Line {
    param([string]$Char = "-", [int]$Width = 66, [string]$Color = "DarkGray")
    Write-Host ("  " + ($Char * $Width)) -ForegroundColor $Color
}

function Show-Header {
    Clear-Host
    $lokal = 0
    if (Test-Path $script:StationDir) {
        $lokal = @(Get-ChildItem -Path $script:StationDir -Filter *.json |
            Where-Object { $_.Name -ne "index.json" }).Count
    }

    Write-Host ""
    Write-Line "=" 66 "Cyan"
    Write-Host ("   Bose SoundTouch Verwaltung" + (" " * 28) + "v$version") -ForegroundColor Cyan
    Write-Line "=" 66 "Cyan"
    Write-Host ""
    Write-Host ("   Sender lokal : {0}" -f $lokal)

    if ($null -eq $script:Device) {
        Write-Host "   Geraet       : keines gewaehlt" -ForegroundColor DarkYellow
    }
    else {
        Write-Host ("   Geraet       : {0}  {1}  (Firmware {2})" -f `
            $script:Device.IPAddress, $script:Device.Name, $script:Device.FirmwareMajor) -ForegroundColor Green
    }
    Write-Host ""
}

function Select-SoundtouchDevice {
    <#
    .SYNOPSIS
        Sucht Boxen im Netz und laesst eine auswaehlen.
    #>
    [CmdletBinding()]
    param([string[]]$Subnet)

    Write-Host ""
    Write-Host "Suche SoundTouch-Geraete..." -ForegroundColor Cyan
    Write-Host "(TCP-Scan auf Port 8090, mDNS funktioniert nicht ueber VLAN-Grenzen)" -ForegroundColor DarkGray
    Write-Host ""

    $devices = @(Find-Soundtouch -Subnet $Subnet)

    if ($devices.Count -eq 0) {
        Write-Host "Keine Geraete gefunden." -ForegroundColor Red
        $manual = Read-Host "IP-Adresse manuell eingeben (leer = abbrechen)"
        if ([string]::IsNullOrWhiteSpace($manual)) { return }
        $info = Get-SoundtouchInfo -IPAddress $manual
        if ($null -ne $info) { $script:Device = $info }
        return
    }

    Write-Host ("{0} Geraet(e) gefunden:" -f $devices.Count) -ForegroundColor Green
    Write-Host ""
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $d = $devices[$i]
        $flag = "OK "
        $col = "Gray"
        if (-not $d.Supported) { $flag = "ALT"; $col = "Red" }
        Write-Host ("   [{0}] {1,-15} {2,-18} FW {3}  {4}" -f `
            ($i + 1), $d.IPAddress, $d.Name, $d.FirmwareMajor, $flag) -ForegroundColor $col
    }
    Write-Host ""

    $sel = Read-Host "Nummer waehlen (leer = abbrechen)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }

    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $devices.Count) {
        Write-Host "Ungueltige Auswahl." -ForegroundColor Red
        return
    }

    $script:Device = $devices[$n - 1]
    Write-Host ("Gewaehlt: {0}" -f $script:Device.IPAddress) -ForegroundColor Green
}

function Select-StationSlug {
    <#
        Laesst einen Sender aus dem lokalen Katalog auswaehlen.
        Gibt den Slug zurueck oder $null bei Abbruch.
    #>
    [CmdletBinding()]
    param([string]$Titel = "Sender waehlen")

    $alle = @(Get-ChildItem -Path $script:StationDir -Filter "*.json" |
        Where-Object { $_.Name -ne "index.json" } | Sort-Object Name)
    if ($alle.Count -eq 0) {
        Write-Host "Keine Senderdateien vorhanden." -ForegroundColor Red
        return $null
    }

    while ($true) {
        Write-Host ""
        Write-Host ("$Titel  ({0} im Katalog)" -f $alle.Count) -ForegroundColor Cyan
        $filter = Read-Host "  Suchbegriff (leer = ueberspringen)"
        if ([string]::IsNullOrWhiteSpace($filter)) { return $null }

        $treffer = @($alle | Where-Object { $_.BaseName -like "*$filter*" })
        if ($treffer.Count -eq 0) {
            Write-Host "  Kein Treffer." -ForegroundColor Yellow
            continue
        }

        $max = [Math]::Min($treffer.Count, 25)
        Write-Host ""
        for ($i = 0; $i -lt $max; $i++) {
            Write-Host ("    [{0,2}] {1}" -f ($i + 1), $treffer[$i].BaseName)
        }
        if ($treffer.Count -gt $max) {
            Write-Host ("    ... und {0} weitere, bitte genauer filtern" -f ($treffer.Count - $max)) -ForegroundColor DarkGray
        }

        Write-Host ""
        $sel = Read-Host "  Nummer (leer = neu suchen)"
        if ([string]::IsNullOrWhiteSpace($sel)) { continue }

        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $max) {
            return $treffer[$n - 1].BaseName
        }
        Write-Host "  Ungueltige Auswahl." -ForegroundColor Red
    }
}

function Set-PresetAssignment {
    <#
    .SYNOPSIS
        Fragt interaktiv, womit die Preset-Tasten belegt werden sollen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IPAddress
    )

    # Nicht $profile nennen - das ist eine automatische PowerShell-Variable
    $profilNamen = @()
    if (Test-Path $script:PresetPath) {
        try {
            $map = (Get-Content $script:PresetPath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($map.PSObject.Properties.Match("profile").Count -gt 0) {
                $profilNamen = @($map.profile.PSObject.Properties.Name)
            }
        }
        catch { Write-Warning "presets.json nicht lesbar: $_" }
    }

    Write-Host ""
    Write-Host "Preset-Tasten belegen" -ForegroundColor Cyan
    Write-Host ""
    if ($profilNamen.Count -gt 0) {
        Write-Host ("   [1] Fertiges Profil verwenden ({0})" -f ($profilNamen -join ", "))
    }
    Write-Host "   [2] Sender einzeln auswaehlen (Tasten 1-6)"
    Write-Host "   [3] Vorerst leer lassen"
    Write-Host ""

    $wahl = Read-Host "   Auswahl"

    switch ($wahl) {
        "1" {
            if ($profilNamen.Count -eq 0) { Write-Host "Keine Profile vorhanden." -ForegroundColor Red; return }
            $name = $profilNamen[0]
            if ($profilNamen.Count -gt 1) {
                $eingabe = Read-Host ("   Profilname (leer = {0})" -f $profilNamen[0])
                if (-not [string]::IsNullOrWhiteSpace($eingabe)) { $name = $eingabe }
            }
            Set-SoundtouchPresetSet -IPAddress $IPAddress -ProfileName $name
        }
        "2" {
            foreach ($slot in 1..6) {
                $slug = Select-StationSlug -Titel ("Taste $slot")
                if ([string]::IsNullOrWhiteSpace($slug)) {
                    Write-Host ("  Taste {0} bleibt unbelegt." -f $slot) -ForegroundColor DarkGray
                    continue
                }
                Set-SoundtouchPreset -IPAddress $IPAddress -Preset $slot -Slug $slug |
                    ForEach-Object { Write-Host ("  Taste {0} -> {1}" -f $_.Preset, $_.Name) -ForegroundColor Green }
                Start-Sleep -Milliseconds 500
            }
        }
        default { Write-Host "Uebersprungen." -ForegroundColor DarkGray }
    }
}

function Invoke-GuidedInstall {
    <#
        Fuehrt durch die Einrichtung einer Box: pruefen, migrieren,
        Registry umbiegen, Presets setzen.
    #>
    if ($null -eq $script:Device) {
        Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red
        return
    }

    $ip = $script:Device.IPAddress
    Write-Host ""
    Write-Host "Schritt 1: Ausgangslage pruefen" -ForegroundColor Cyan
    $test = @(Test-SoundtouchSetup -IPAddress $ip)
    $test | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

    # --- Fabrikfrische Box: Quelle erst bereitstellen ---
    $lir = $test | Where-Object { $_.Pruefung -eq "Quelle LOCAL_INTERNET_RADIO" }
    if ($null -ne $lir -and $lir.Ergebnis -ne "OK") {
        Write-Host ""
        Write-Host "Die Quelle LOCAL_INTERNET_RADIO fehlt - das ist eine fabrikfrische Box." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Sie muss zuerst vorbereitet werden. Dazu wird einmalig der Installer" -ForegroundColor Gray
        Write-Host "von SoundPloy angestossen, der ueber einfaches HTTP arbeitet und auf" -ForegroundColor Gray
        Write-Host "dieser Hardware erprobt ist. Die Box vertraut diesem fremden Server" -ForegroundColor Gray
        Write-Host "damit fuer genau einen Bootvorgang, danach uebernimmt dieses Repo." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Nebenwirkungen:" -ForegroundColor Yellow
        Write-Host "    - Eine vorhandene Spotify-Verknuepfung geht verloren" -ForegroundColor Yellow
        Write-Host "    - Bose-Firmwareupdates werden deaktiviert" -ForegroundColor Yellow
        Write-Host "    - Die Box startet zweimal neu (2-3 Minuten)" -ForegroundColor Yellow
        Write-Host ""

        $ok = Read-Host "Vorbereitung jetzt durchfuehren? (j/n)"
        if ($ok -ne "j") {
            Write-Host "Abgebrochen. Ohne diesen Schritt geht es nicht weiter." -ForegroundColor DarkGray
            return
        }

        Install-BoseRadioFactory -IPAddress $ip -Confirm
        Write-Host ""
        Write-Host "Warte auf Neustart..." -ForegroundColor Cyan
        [void](Wait-Soundtouch -IPAddress $ip)
        Start-Sleep -Seconds 20

        Write-Host ""
        Write-Host "Kontrolle nach der Vorbereitung:" -ForegroundColor Cyan
        $test = @(Test-SoundtouchSetup -IPAddress $ip)
        $test | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

        $lir = $test | Where-Object { $_.Pruefung -eq "Quelle LOCAL_INTERNET_RADIO" }
        if ($null -eq $lir -or $lir.Ergebnis -ne "OK") {
            Write-Host "Die Quelle ist weiterhin nicht bereit - hier von Hand weitersuchen." -ForegroundColor Red
            Write-Host "Moegliche Ursache: Die Box kam nicht ins Internet." -ForegroundColor Yellow
            return
        }
        Write-Host "Vorbereitung erfolgreich." -ForegroundColor Green
    }

    # --- Vorhandene Presets uebernehmen ---
    Write-Host ""
    Write-Host "Schritt 2: Vorhandene Presets migrieren" -ForegroundColor Cyan
    $vorhanden = @(Get-SoundtouchPreset -IPAddress $ip)
    if ($vorhanden.Count -eq 0) {
        Write-Host "Keine vorhandenen Presets - nichts zu migrieren." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Fehlende Senderdateien werden lokal angelegt." -ForegroundColor DarkGray
        $plan = @(Convert-SoundtouchPreset -IPAddress $ip)
        if ($plan.Count -gt 0) { $plan | Format-Table -AutoSize | Out-String -Width 120 | Write-Host }

        $neu = @($plan | Where-Object { $_.Datei -eq "angelegt" })
        if ($neu.Count -gt 0) {
            Write-Host ""
            Write-Host ("{0} neue Datei(en) angelegt. Jetzt committen und pushen:" -f $neu.Count) -ForegroundColor Yellow
            Write-Host '   git add stations/ ; git commit -m "Sender" ; git push' -ForegroundColor White
            Write-Host ""
            $weiter = Read-Host "Gepusht? Dann Enter zum Fortfahren, sonst 'n'"
            if ($weiter -eq "n") { return }
        }
    }

    # --- Registry auf das eigene Repo ---
    Write-Host ""
    Write-Host "Schritt 3: Registry auf dieses Repo umbiegen" -ForegroundColor Cyan
    Write-Host "Erst danach ist die Box von soundploy.gmuth.de unabhaengig." -ForegroundColor DarkGray
    Write-Host "Die Box startet dabei neu." -ForegroundColor DarkGray
    $ok = Read-Host "Ausfuehren? (j/n)"
    if ($ok -eq "j") {
        Install-BoseRadio -IPAddress $ip -Confirm
        Write-Host ""
        Write-Host "Warte auf Neustart..." -ForegroundColor Cyan
        [void](Wait-Soundtouch -IPAddress $ip)
        Start-Sleep -Seconds 10
    }

    # --- Presets ---
    Write-Host ""
    Write-Host "Schritt 4: Presets" -ForegroundColor Cyan
    if ($vorhanden.Count -gt 0) {
        Write-Host "Uebernehme die migrierten Presets..." -ForegroundColor DarkGray
        [void](Convert-SoundtouchPreset -IPAddress $ip -Apply)
        Write-Host ""
        $mehr = Read-Host "Belegung zusaetzlich von Hand anpassen? (j/n)"
        if ($mehr -eq "j") { Set-PresetAssignment -IPAddress $ip }
    }
    else {
        Set-PresetAssignment -IPAddress $ip
    }

    # --- Ergebnis ---
    Write-Host ""
    Write-Host "Schritt 5: Ergebnis" -ForegroundColor Cyan
    Test-SoundtouchSetup -IPAddress $ip | Format-Table -AutoSize | Out-String -Width 120 | Write-Host
    Get-SoundtouchPreset -IPAddress $ip | Format-Table Preset, Name, IsOwn -AutoSize | Out-String -Width 120 | Write-Host
    Write-Host "Zum Abschluss eine Preset-Taste am Geraet druecken und hoeren." -ForegroundColor Yellow
}

function Add-StationInteractive {
    Write-Host ""
    $suche = Read-Host "Sendername"
    if ([string]::IsNullOrWhiteSpace($suche)) { return }

    $hits = @(Find-RadioStation -Name $suche -Limit 10)
    if ($hits.Count -eq 0) {
        Write-Host "Keine Treffer." -ForegroundColor Red
        return
    }

    Write-Host ""
    for ($i = 0; $i -lt $hits.Count; $i++) {
        Write-Host ("   [{0}] {1,-38} {2,-12} {3}" -f `
            ($i + 1), $hits[$i].Name, $hits[$i].Country, $hits[$i].StreamUrl)
    }
    Write-Host ""

    $sel = Read-Host "Nummer waehlen (leer = abbrechen)"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $hits.Count) {
        Write-Host "Ungueltige Auswahl." -ForegroundColor Red
        return
    }

    $res = $hits[$n - 1] | New-StationFile -Force
    if ($null -ne $res) {
        Write-Host ("{0}: {1}" -f $res.Status, $res.Path) -ForegroundColor Green
        Write-Host "Committen und pushen, dann ist der Sender verwendbar." -ForegroundColor Yellow
    }
}

function Set-PresetInteractive {
    if ($null -eq $script:Device) {
        Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red
        return
    }

    $files = @(Get-ChildItem -Path $script:StationDir -Filter *.json |
        Where-Object { $_.Name -ne "index.json" } | Sort-Object Name)
    if ($files.Count -eq 0) {
        Write-Host "Keine Senderdateien vorhanden." -ForegroundColor Red
        return
    }

    $filter = Read-Host "Filter (leer = alle)"
    if (-not [string]::IsNullOrWhiteSpace($filter)) {
        $files = @($files | Where-Object { $_.BaseName -like "*$filter*" })
    }
    if ($files.Count -eq 0) {
        Write-Host "Kein Sender passt zum Filter." -ForegroundColor Red
        return
    }

    Write-Host ""
    $max = [Math]::Min($files.Count, 40)
    for ($i = 0; $i -lt $max; $i++) {
        Write-Host ("   [{0,3}] {1}" -f ($i + 1), $files[$i].BaseName)
    }
    if ($files.Count -gt $max) {
        Write-Host ("   ... und {0} weitere, bitte filtern" -f ($files.Count - $max)) -ForegroundColor DarkGray
    }
    Write-Host ""

    $sel = Read-Host "Sender-Nummer"
    $n = 0
    if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $max) {
        Write-Host "Ungueltige Auswahl." -ForegroundColor Red
        return
    }

    $slot = Read-Host "Auf welche Taste (1-6)"
    $s = 0
    if (-not [int]::TryParse($slot, [ref]$s) -or $s -lt 1 -or $s -gt 6) {
        Write-Host "Ungueltige Taste." -ForegroundColor Red
        return
    }

    Set-SoundtouchPreset -IPAddress $script:Device.IPAddress -Preset $s -Slug $files[$n - 1].BaseName |
        Format-List | Out-String | Write-Host
}

function Start-SoundtouchManager {
    <#
    .SYNOPSIS
        Startet das Menue.
    #>
    [CmdletBinding()]
    param()

    while ($true) {
        Show-Header

        Write-Line
        Write-Host "   [1]  Geraete suchen und auswaehlen"
        Write-Host "   [2]  Status des gewaehlten Geraets"
        Write-Host "   [3]  Presets anzeigen"
        Write-Host "   [4]  Einrichtung / Migration  (gefuehrt)" -ForegroundColor Cyan
        Write-Host "   [5]  Presets aus Profil setzen"
        Write-Host "   [6]  Einzelnes Preset setzen"
        Write-Host "   [7]  Senderkatalog aktualisieren (Top 100 DE)"
        Write-Host "   [8]  Sender suchen und hinzufuegen"
        Write-Host "   [T]  Senderdateien pruefen (Streams erreichbar?)"
        Write-Host "   [9]  Registry umbiegen (Telnet, Neustart)" -ForegroundColor DarkYellow
        Write-Host "   [R]  Boot-Hook entschaerfen" -ForegroundColor DarkYellow
        Write-Host "   [Q]  Beenden"
        Write-Line
        Write-Host ""

        $wahl = Read-Host "   Auswahl"
        Write-Host ""

        try {
            switch ($wahl.ToUpperInvariant()) {
                "1" { Select-SoundtouchDevice }
                "2" {
                    if ($null -eq $script:Device) { Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red }
                    else { Test-SoundtouchSetup -IPAddress $script:Device.IPAddress | Format-Table -AutoSize | Out-String -Width 120 | Write-Host }
                }
                "3" {
                    if ($null -eq $script:Device) { Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red }
                    else { Get-SoundtouchPreset -IPAddress $script:Device.IPAddress | Format-Table Preset, Name, Source, IsOwn -AutoSize | Out-String -Width 120 | Write-Host }
                }
                "4" { Invoke-GuidedInstall }
                "5" {
                    if ($null -eq $script:Device) { Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red }
                    else {
                        $prof = Read-Host "Profilname (leer = standard)"
                        if ([string]::IsNullOrWhiteSpace($prof)) { $prof = "standard" }
                        Set-SoundtouchPresetSet -IPAddress $script:Device.IPAddress -ProfileName $prof
                    }
                }
                "6" { Set-PresetInteractive }
                "7" {
                    $anz = Read-Host "Wie viele Sender (leer = 100)"
                    $t = 100
                    if (-not [string]::IsNullOrWhiteSpace($anz)) { [void][int]::TryParse($anz, [ref]$t) }
                    $land = Read-Host "Laendercode (leer = DE)"
                    if ([string]::IsNullOrWhiteSpace($land)) { $land = "DE" }
                    Update-StationCatalog -Top $t -CountryCode $land | Out-Null
                }
                "8" { Add-StationInteractive }
                "T" {
                    Write-Host "Pruefe alle Senderdateien, das dauert einen Moment..." -ForegroundColor Cyan
                    $res = @(Test-StationFiles)
                    $schlecht = @($res | Where-Object { -not $_.Ok })
                    Write-Host ""
                    Write-Host ("{0} von {1} erreichbar." -f ($res.Count - $schlecht.Count), $res.Count) -ForegroundColor Green
                    if ($schlecht.Count -gt 0) {
                        Write-Host ""
                        Write-Host "Nicht erreichbar:" -ForegroundColor Red
                        $schlecht | Format-Table Slug, Name, Status -AutoSize | Out-String -Width 140 | Write-Host
                    }
                }
                "9" {
                    if ($null -eq $script:Device) { Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red }
                    else {
                        Install-BoseRadio -IPAddress $script:Device.IPAddress
                        $ok = Read-Host "Wirklich ausfuehren? Die Box startet neu (j/n)"
                        if ($ok -eq "j") {
                            Install-BoseRadio -IPAddress $script:Device.IPAddress -Confirm
                            [void](Wait-Soundtouch -IPAddress $script:Device.IPAddress)
                        }
                    }
                }
                "R" {
                    if ($null -eq $script:Device) { Write-Host "Erst ein Geraet waehlen." -ForegroundColor Red }
                    else {
                        Reset-BoseBootHook -IPAddress $script:Device.IPAddress
                        $ok = Read-Host "Wirklich ausfuehren? (j/n)"
                        if ($ok -eq "j") { Reset-BoseBootHook -IPAddress $script:Device.IPAddress -Confirm }
                    }
                }
                "Q" { return }
                default { Write-Host "Unbekannte Auswahl." -ForegroundColor Red }
            }
        }
        catch {
            Write-Error $_
        }

        Write-Host ""
        [void](Read-Host "   Weiter mit Enter")
    }
}

# ===================================================================
#  Start
# ===================================================================

# Beim Dot-Sourcing ist InvocationName ".", dann nur Funktionen bereitstellen.
if ($MyInvocation.InvocationName -ne ".") {
    Start-SoundtouchManager
}
else {
    Write-Output "Soundtouch-Tools v$version geladen (Menue: Start-SoundtouchManager)."
}
