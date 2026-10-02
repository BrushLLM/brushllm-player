# BrushLLM Player

[Website](https://www.brushllm.com) · [Releases](https://github.com/BrushLLM/brushllm-player/releases)

An open-source macOS media player built on libmpv — plays virtually every format, streams from WebDAV / SMB / FTP / Emby / Jellyfin, and ships a 9-language UI.

[English](#english) | [Deutsch](#deutsch) | [Español](#espa%C3%B1ol) | [Français](#fran%C3%A7ais) | [Português (BR)](#portugu%C3%AAs-br) | [简体中文](#%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87) | [繁體中文](#%E7%B9%81%E9%AB%94%E4%B8%AD%E6%96%87) | [日本語](#%E6%97%A5%E6%9C%AC%E8%AA%9E) | [한국어](#%ED%95%9C%EA%B5%AD%EC%96%B4)

## English

### ✨ Features

**Playback** — powered by libmpv:
- Every format mpv supports (MKV, MP4, AVI, MOV, WebM, FLAC, MP3, …)
- Hardware decoding (VideoToolbox) with live toggle
- HDR output (PQ + EDR), A-B loop, playback speed, frame stepping
- ISO disc images: Blu-ray (largest title) and DVD (seamless multi-VOB via EDL)

**Media servers** — browse and play directly from:
- WebDAV, SMB (native macOS mount), FTP
- Emby / Jellyfin (login, library browsing, direct-stream playback)

**Network streams**:
- HTTP(S) direct links and m3u8/HLS
- Adjustable read-ahead buffer and User-Agent

**Subtitles**:
- Auto-load matching sidecar files
- External subtitle files, live styling (font, size, color, position)

**Library & tools**:
- Playlist with drag-reorder, chapters, history with resume, bookmarks
- Screenshots, stream recording, equalizer, mini floating window

**9-language UI** — switch instantly in Settings.

### 📥 Download

Grab the latest [release](https://github.com/BrushLLM/brushllm-player/releases):

| Platform | File |
|---|---|
| macOS — Apple Silicon (M-series) | `.dmg` |

The app is unsigned — on first launch, right-click and choose **Open**.

### 🛠 Develop

```bash
./scripts/build-app.sh debug     # build + assemble .app
./scripts/build-app.sh release   # optimized build
open "build/BrushLLM Player.app"
```

Requires Xcode 15+ (Swift 5.9). Swift Package Manager resolves MPVKit automatically.

### Architecture

- **UI** — Swift 5 + SwiftUI + AppKit, dark glass design system
- **Playback core** — libmpv via [MPVKit](https://github.com/MPVKit/MPVKit) (GPL build), OpenGL render API
- **Localization** — 9 language tables compiled into the binary; runtime switching with no restart
- **Media servers** — URLSession (WebDAV PROPFIND, Emby/Jellyfin REST), Network.framework (FTP), mount_smbfs (SMB)
- **Persistence** — UserDefaults (settings), Keychain (server passwords/tokens), JSON (history/bookmarks)

### Known limitations

- macOS only (Apple Silicon) — a Windows release via a cross-platform rewrite is planned
- Apps are unsigned — Gatekeeper shows a first-run warning
- GPL v3 (libmpv licensing)

---

## Deutsch

BrushLLM Player ist ein Open-Source-Mediaplayer für macOS auf libmpv-Basis — spielt praktisch jedes Format, streamt von WebDAV / SMB / FTP / Emby / Jellyfin und bietet eine 9-sprachige Oberfläche.

**Funktionen**: Hardware-Dekodierung · HDR · A-B-Wiederholung · Geschwindigkeit · Einzelbildschritte · ISO-Disc-Images (Blu-ray/DVD) · WebDAV, SMB, FTP, Emby/Jellyfin · HTTP/HLS-Streams · Untertitel (automatisch laden, externe Dateien, Live-Styling) · Wiedergabeliste · Kapitel · Verlauf mit Fortsetzen · Lesezeichen · Screenshots · Aufnahmen · Equalizer · Mini-Fenster

**Download**: [Releases](https://github.com/BrushLLM/brushllm-player/releases) — `.dmg` für Apple Silicon. Die App ist unsigniert — beim ersten Start rechtsklicken und „Öffnen" wählen.

Entwicklung und Architektur: siehe [English](#english).

---

## Español

BrushLLM Player es un reproductor multimedia de código abierto para macOS basado en libmpv — reproduce casi cualquier formato, transmite desde WebDAV / SMB / FTP / Emby / Jellyfin e incluye una interfaz en 9 idiomas.

**Funciones**: decodificación por hardware · HDR · bucle A-B · velocidad · avance por fotogramas · imágenes de disco ISO (Blu-ray/DVD) · WebDAV, SMB, FTP, Emby/Jellyfin · transmisiones HTTP/HLS · subtítulos (carga automática, archivos externos, estilo en vivo) · lista de reproducción · capítulos · historial con reanudación · marcadores · capturas · grabaciones · ecualizador · mini ventana

**Descarga**: [Releases](https://github.com/BrushLLM/brushllm-player/releases) — `.dmg` para Apple Silicon. La app no está firmada — en el primer inicio, clic derecho y elegir *Abrir*.

Desarrollo y arquitectura: ver [English](#english).

---

## Français

BrushLLM Player est un lecteur multimédia open source pour macOS basé sur libmpv — lit pratiquement tous les formats, diffuse depuis WebDAV / SMB / FTP / Emby / Jellyfin et propose une interface en 9 langues.

**Fonctions** : décodage matériel · HDR · boucle A-B · vitesse · pas à pas image · images disque ISO (Blu-ray/DVD) · WebDAV, SMB, FTP, Emby/Jellyfin · flux HTTP/HLS · sous-titres (chargement auto, fichiers externes, style en direct) · liste de lecture · chapitres · historique avec reprise · favoris · captures · enregistrements · égaliseur · mini-fenêtre

**Téléchargement** : [Releases](https://github.com/BrushLLM/brushllm-player/releases) — `.dmg` pour Apple Silicon. L'app n'est pas signée — au premier lancement, clic droit puis *Ouvrir*.

Développement et architecture : voir [English](#english).

---

## Português (BR)

O BrushLLM Player é um reprodutor de mídia de código aberto para macOS baseado em libmpv — reproduz praticamente qualquer formato, transmite de WebDAV / SMB / FTP / Emby / Jellyfin e tem interface em 9 idiomas.

**Recursos**: decodificação por hardware · HDR · loop A-B · velocidade · avanço por quadro · imagens de disco ISO (Blu-ray/DVD) · WebDAV, SMB, FTP, Emby/Jellyfin · streams HTTP/HLS · legendas (carregamento automático, arquivos externos, estilo ao vivo) · playlist · capítulos · histórico com retomada · marcadores · capturas de tela · gravações · equalizador · mini janela

**Download**: [Releases](https://github.com/BrushLLM/brushllm-player/releases) — `.dmg` para Apple Silicon. O app não é assinado — no primeiro uso, clique com o botão direito e escolha *Abrir*.

Desenvolvimento e arquitetura: veja [English](#english).

---

## 简体中文

BrushLLM Player 是一个基于 libmpv 的开源 macOS 媒体播放器 —— 支持几乎所有格式，可从 WebDAV / SMB / FTP / Emby / Jellyfin 流媒体服务器直接播放，内置 9 语言界面。

**功能**：硬件解码 · HDR 输出 · A-B 循环 · 变速播放 · 逐帧步进 · ISO 光盘镜像（蓝光/DVD）· WebDAV、SMB、FTP、Emby/Jellyfin 媒体服务器 · HTTP/HLS 网络流 · 字幕（自动加载、外部文件、实时样式调整）· 播放列表 · 章节 · 带断点续播的历史记录 · 书签 · 截图 · 录制 · 均衡器 · 迷你悬浮窗

**下载**：[Releases](https://github.com/BrushLLM/brushllm-player/releases) —— Apple Silicon 的 `.dmg`。应用未签名 —— 首次启动请右键选择"打开"。

开发与架构详情见 [English](#english)。

---

## 繁體中文

BrushLLM Player 是一個基於 libmpv 的開源 macOS 媒體播放器 —— 支援幾乎所有格式，可從 WebDAV / SMB / FTP / Emby / Jellyfin 串流伺服器直接播放，內建 9 語言介面。

**功能**：硬體解碼 · HDR 輸出 · A-B 循環 · 變速播放 · 逐幀步進 · ISO 光碟映像檔（藍光/DVD）· WebDAV、SMB、FTP、Emby/Jellyfin 媒體伺服器 · HTTP/HLS 網路串流 · 字幕（自動載入、外部檔案、即時樣式調整）· 播放清單 · 章節 · 帶斷點續播的歷史記錄 · 書籤 · 截圖 · 錄製 · 等化器 · 迷你懸浮窗

**下載**：[Releases](https://github.com/BrushLLM/brushllm-player/releases) —— Apple Silicon 的 `.dmg`。應用程式未簽署 —— 首次啟動請右鍵選擇「開啟」。

開發與架構詳情見 [English](#english)。

---

## 日本語

BrushLLM Player は libmpv ベースのオープンソース macOS メディアプレイヤーです。ほぼすべての形式を再生し、WebDAV / SMB / FTP / Emby / Jellyfin から直接ストリーミングでき、9 言語の UI を搭載しています。

**機能**：ハードウェアデコード · HDR 出力 · A-B ループ · 速度変更 · コマ送り · ISO ディスクイメージ（Blu-ray/DVD）· WebDAV、SMB、FTP、Emby/Jellyfin · HTTP/HLS ストリーム · 字幕（自動読み込み、外部ファイル、ライブスタイル調整）· プレイリスト · チャプター · レジューム付き履歴 · ブックマーク · スクリーンショット · 録画 · イコライザー · ミニウィンドウ

**ダウンロード**：[Releases](https://github.com/BrushLLM/brushllm-player/releases) —— Apple Silicon 用の `.dmg`。アプリは未署名です —— 初回起動時に右クリックして「開く」を選択してください。

開発とアーキテクチャの詳細は [English](#english) を参照。

---

## 한국어

BrushLLM Player는 libmpv 기반의 오픈소스 macOS 미디어 플레이어입니다. 거의 모든 형식을 재생하고, WebDAV / SMB / FTP / Emby / Jellyfin에서 직접 스트리밍할 수 있으며, 9개 언어 UI를 제공합니다.

**기능**: 하드웨어 디코딩 · HDR 출력 · A-B 루프 · 배속 재생 · 프레임 단위 이동 · ISO 디스크 이미지(블루레이/DVD) · WebDAV, SMB, FTP, Emby/Jellyfin · HTTP/HLS 스트림 · 자막(자동 불러오기, 외부 파일, 실시간 스타일 조정) · 재생목록 · 챕터 · 이어보기 기록 · 북마크 · 스크린샷 · 녹화 · 이퀄라이저 · 미니 창

**다운로드**: [Releases](https://github.com/BrushLLM/brushllm-player/releases) —— Apple Silicon용 `.dmg`. 앱은 서명되지 않았습니다 —— 첫 실행 시 마우스 오른쪽 클릭으로 *열기*를 선택하세요.

개발 및 아키텍처 세부 사항은 [English](#english)를 참조하세요.
