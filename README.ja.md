# BrushLLM Player

[English](README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

mpv ベースのオープンソース・クロスプラットフォームメディアプレイヤーです。ほぼすべての形式を再生し、WebDAV / SMB / FTP / Emby / Jellyfin から直接ストリーミングでき、9 言語の UI を搭載しています。

## 機能

- **再生** — mpv が対応するほぼすべての形式（MKV、MP4、AVI、MOV、WebM、FLAC、MP3 など）· ハードウェアデコード（VideoToolbox、ライブ切替）· HDR 出力（PQ + EDR）· ISO ディスクイメージ（Blu-ray メインタイトル、DVD を EDL でシームレスに）· A-B ループ · 速度変更 · コマ送り · チャプター
- **メディアサーバー** — **WebDAV、SMB、FTP、Emby、Jellyfin** を直接ブラウズして再生。並べ替え可能なブラウザ（名前 / 更新日時 / サイズ）とフォルダーからプレイリストへ
- **ネットワークストリーム** — HTTP(S) 直接リンクと m3u8/HLS。先読みバッファーと User-Agent を調整可能
- **字幕** — 一致するファイルの自動読み込み、外部字幕、ライブスタイル調整（フォント、サイズ、色、位置）
- **ライブラリとツール** — ドラッグで並べ替えるプレイリスト · レジューム付き履歴 · ブックマーク · スクリーンショット · 録画 · イコライザー · ミニウィンドウ
- **その他** — 9 言語 UI の即時切替 · 手動アップデート確認 · テレメトリなし

## ダウンロード

最新のインストーラーは [Releases](https://github.com/BrushLLM/brushllm-player/releases) から：

| プラットフォーム | ファイル |
| --- | --- |
| macOS — Apple Silicon（M シリーズ） | `.dmg`（arm64） |
| Windows 10/11 — x64（Intel / AMD） | `.exe`（x64） |
| Windows 10/11 — ARM64（Snapdragon） | `.exe`（arm64） |

> **アプリは未署名です。** macOS：初回起動時に右クリックで「開く」を選択（Gatekeeper）。Windows：SmartScreen の警告で「実行」を選択 — インストーラーは 9 言語のセレクター付きで開き、mpv を同梱しているため追加ダウンロードは不要です。

## ライセンス

GPL v3（mpv / libmpv のライセンス）の下で提供 — [LICENSE](LICENSE) を参照。

開発とアーキテクチャの詳細は [English](README.md) を参照。
