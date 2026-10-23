# BrushLLM Player

[English](../README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

Un reproductor multimedia de código abierto basado en mpv — reproduce casi cualquier formato, transmite desde WebDAV / SMB / FTP / Emby / Jellyfin e incluye una interfaz en 9 idiomas.

## Funciones

- **Reproducción** — casi cualquier formato compatible con mpv (MKV, MP4, AVI, MOV, WebM, FLAC, MP3, …) · decodificación por hardware (VideoToolbox, conmutación en vivo) · salida HDR (PQ + EDR) · imágenes de disco ISO (título principal de Blu-ray, DVD sin cortes vía EDL) · bucle A-B · velocidad · avance por fotogramas · capítulos
- **Servidores multimedia** — explora y reproduce directamente desde **WebDAV, SMB, FTP, Emby y Jellyfin**; navegador ordenable (nombre / modificación / tamaño) y carpeta-a-lista-de-reproducción
- **Transmisiones de red** — enlaces directos HTTP(S) y m3u8/HLS, con búfer de lectura anticipada y User-Agent ajustables
- **Subtítulos** — carga automática de archivos coincidentes, subtítulos externos, estilo en vivo (fuente, tamaño, color, posición)
- **Biblioteca y herramientas** — lista de reproducción con reordenar arrastrando · historial con reanudación · marcadores · capturas · grabaciones · ecualizador · mini ventana
- **Además** — interfaz en 9 idiomas con cambio instantáneo · comprobación manual de actualizaciones · sin telemetría

## Descarga

Instaladores actuales en [Releases](https://github.com/BrushLLM/brushllm-player/releases):

| Plataforma | Archivo |
| --- | --- |
| macOS — Apple Silicon (serie M) | `.dmg` (arm64) |
| Windows 10/11 — x64 (Intel/AMD) | `.exe` (x64) |
| Windows 10/11 — ARM64 (Snapdragon) | `.exe` (arm64) |

> **Las apps no están firmadas.** macOS: en el primer inicio, clic derecho en la app → *Abrir* (Gatekeeper). Windows: elegir *Ejecutar de todas formas* cuando aparezca SmartScreen — el instalador se abre con un selector de 9 idiomas e incluye mpv, sin descargas adicionales.

## Licencia

Licenciado bajo GPL v3 (licencias de mpv / libmpv) — ver [LICENSE](../LICENSE).

Desarrollo y arquitectura: ver [English](../README.md).
