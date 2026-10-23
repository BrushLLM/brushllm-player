# BrushLLM Player

[English](README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

Um reprodutor de mídia de código aberto baseado em mpv — reproduz praticamente qualquer formato, transmite de WebDAV / SMB / FTP / Emby / Jellyfin e tem interface em 9 idiomas.

## Recursos

- **Reprodução** — praticamente todo formato suportado pelo mpv (MKV, MP4, AVI, MOV, WebM, FLAC, MP3, …) · decodificação por hardware (VideoToolbox, alternância ao vivo) · saída HDR (PQ + EDR) · imagens de disco ISO (título principal de Blu-ray, DVD contínuo via EDL) · loop A-B · velocidade · avanço por quadro · capítulos
- **Servidores de mídia** — navegue e reproduza diretamente de **WebDAV, SMB, FTP, Emby e Jellyfin**; navegador ordenável (nome / modificação / tamanho) e pasta-para-playlist
- **Streams de rede** — links diretos HTTP(S) e m3u8/HLS, com buffer de leitura antecipada e User-Agent ajustáveis
- **Legendas** — carregamento automático de arquivos correspondentes, legendas externas, estilo ao vivo (fonte, tamanho, cor, posição)
- **Biblioteca e ferramentas** — playlist com reordenação por arrastar · histórico com retomada · marcadores · capturas de tela · gravações · equalizador · mini janela
- **Também** — interface em 9 idiomas com troca instantânea · verificação manual de atualizações · zero telemetria

## Download

Instaladores atuais em [Releases](https://github.com/BrushLLM/brushllm-player/releases):

| Plataforma | Arquivo |
| --- | --- |
| macOS — Apple Silicon (série M) | `.dmg` (arm64) |
| Windows 10/11 — x64 (Intel/AMD) | `.exe` (x64) |
| Windows 10/11 — ARM64 (Snapdragon) | `.exe` (arm64) |

> **Os apps não são assinados.** No primeiro uso, macOS: clique com o botão direito no app → *Abrir* (Gatekeeper). Windows: escolha *Executar assim mesmo* quando o SmartScreen aparecer — o instalador abre com um seletor de 9 idiomas e inclui o mpv, sem downloads extras.

## Licença

Licenciado sob GPL v3 (licenciamento mpv / libmpv) — veja [LICENSE](LICENSE).

Desenvolvimento e arquitetura: veja [English](README.md).
