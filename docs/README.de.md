# BrushLLM Player

[English](../README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

Ein Open-Source-Mediaplayer auf mpv-Basis — spielt praktisch jedes Format, streamt von WebDAV / SMB / FTP / Emby / Jellyfin und bietet eine 9-sprachige Oberfläche.

## Funktionen

- **Wiedergabe** — jedes von mpv unterstützte Format (MKV, MP4, AVI, MOV, WebM, FLAC, MP3, …) · Hardware-Dekodierung (VideoToolbox, live umschaltbar) · HDR-Ausgabe (PQ + EDR) · ISO-Disc-Images (Blu-ray Haupttitel, DVD nahtlos über EDL) · A-B-Wiederholung · Geschwindigkeit · Einzelbildschritte · Kapitel
- **Medienserver** — direkt aus **WebDAV, SMB, FTP, Emby und Jellyfin** browsen und abspielen; sortierbarer Browser (Name / Geändert / Größe) und Ordner-zur-Wiedergabeliste
- **Netzwerk-Streams** — HTTP(S)-Direktlinks und m3u8/HLS, mit einstellbarem Vorlese-Puffer und User-Agent
- **Untertitel** — automatisch passende Dateien laden, externe Untertitel, Live-Styling (Schrift, Größe, Farbe, Position)
- **Bibliothek & Werkzeuge** — Wiedergabeliste mit Ziehen-umordnen · Verlauf mit Fortsetzen · Lesezeichen · Screenshots · Aufnahmen · Equalizer · Mini-Fenster
- **Außerdem** — 9-sprachige UI mit sofortigem Wechsel · manuelle Update-Prüfung · keine Telemetrie

## Herunterladen

Aktuelle Installationspakete auf [Releases](https://github.com/BrushLLM/brushllm-player/releases):

| Plattform | Datei |
| --- | --- |
| macOS — Apple Silicon (M-Serie) | `.dmg` (arm64) |
| Windows 10/11 — x64 (Intel/AMD) | `.exe` (x64) |
| Windows 10/11 — ARM64 (Snapdragon) | `.exe` (arm64) |

> **Apps sind unsigniert.** macOS: beim ersten Start die App rechtsklicken → **Öffnen** (Gatekeeper). Windows: bei SmartScreen **„Ausführen“** wählen — das Installationsprogramm öffnet sich mit einer 9-sprachigen Auswahl und bringt mpv mit, weitere Downloads sind nicht nötig.

## Lizenz

Lizenziert unter GPL v3 (mpv / libmpv-Lizenzierung) — siehe [LICENSE](../LICENSE).

Entwicklung und Architektur: siehe [English](../README.md).
