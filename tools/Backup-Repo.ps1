#Version
$version = "1.0.0"
$datum = "2026-08-09"
$autor = "Felix Kappen"

<#
.SYNOPSIS
    Sichert dieses Repository als git-Bundle.

.DESCRIPTION
    Ein git-Bundle ist eine einzelne Datei, die das komplette Repository
    samt Historie enthaelt. Daraus laesst sich jederzeit ein vollstaendiges
    Repo wiederherstellen, auch ohne GitHub:

        git clone bose-2026-08-09.bundle bose

    Warum ueberhaupt sichern: Der Lautsprecher laedt seine Senderdateien von
    raw.githubusercontent.com. Wird das Repository geloescht, umbenannt oder
    auf privat gestellt, spielt er kein Radio mehr - und zwar ohne
    Fehlermeldung. Das Bundle stellt sicher, dass der Inhalt in dem Fall
    nicht verloren ist und das Repo unter gleichem Namen neu angelegt werden
    kann.

.EXAMPLE
    .\Backup-Repo.ps1

.EXAMPLE
    .\Backup-Repo.ps1 -Ziel "D:\Backups\bose" -Behalten 10

.NOTES
    PowerShell 5.1 kompatibel.
#>

Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

# Standardziel: neben dem Repo, damit es nicht im Repo selbst landet
$ziel = Join-Path (Split-Path -Parent $repoRoot) "_backup-bose"
$behalten = 14

# Argumente von Hand auswerten - ein param()-Block waere vor dem
# Versionsheader noetig und wuerde diesen ungueltig machen.
for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        '^-Ziel$'      { $i++; if ($i -lt $args.Count) { $ziel = [string]$args[$i] } }
        '^-Behalten$'  { $i++; if ($i -lt $args.Count) { [void][int]::TryParse($args[$i], [ref]$behalten) } }
        default        { Write-Warning "Unbekanntes Argument: $($args[$i])" }
    }
}

try {
    if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
        Write-Error "Kein git-Repository unter $repoRoot"
        return
    }

    if (-not (Test-Path $ziel)) {
        New-Item -ItemType Directory -Path $ziel -Force | Out-Null
        Write-Output "Zielordner angelegt: $ziel"
    }

    # Unversionierte Aenderungen wuerden nicht mitgesichert - darauf hinweisen
    $offen = @(git -C $repoRoot status --porcelain)
    if ($offen.Count -gt 0) {
        Write-Warning "$($offen.Count) nicht committete Aenderung(en) - die sind NICHT im Bundle:"
        $offen | ForEach-Object { Write-Warning "  $_" }
    }

    $stempel = Get-Date -Format "yyyy-MM-dd_HHmm"
    $datei = Join-Path $ziel "bose-$stempel.bundle"

    Write-Output "Erstelle Bundle..."
    git -C $repoRoot bundle create $datei --all
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git bundle create ist fehlgeschlagen (Exitcode $LASTEXITCODE)."
        return
    }

    Write-Output "Pruefe Bundle..."
    git -C $repoRoot bundle verify $datei | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Das erzeugte Bundle ist nicht lesbar."
        return
    }

    $info = Get-Item $datei
    Write-Output ""
    Write-Output ("OK: {0}" -f $info.FullName)
    Write-Output ("    {0:N0} KB" -f ($info.Length / 1KB))

    # Alte Sicherungen aufraeumen
    $alle = @(Get-ChildItem $ziel -Filter "bose-*.bundle" | Sort-Object LastWriteTime -Descending)
    if ($alle.Count -gt $behalten) {
        $weg = $alle | Select-Object -Skip $behalten
        foreach ($w in $weg) {
            Remove-Item $w.FullName -Force
            Write-Output ("    entfernt (aelter als die letzten $behalten): {0}" -f $w.Name)
        }
    }

    Write-Output ""
    Write-Output "Wiederherstellen:"
    Write-Output ("    git clone `"{0}`" bose" -f $info.FullName)
}
catch {
    Write-Error $_
}
