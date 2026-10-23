# BrushLLM Player

[English](README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

一個基於 mpv 的開源跨平台媒體播放器 —— 支援幾乎所有格式，可從 WebDAV / SMB / FTP / Emby / Jellyfin 串流伺服器直接播放，內建 9 語言介面。

## 功能

- **播放** —— mpv 支援的幾乎所有格式（MKV、MP4、AVI、MOV、WebM、FLAC、MP3 等）· 硬體解碼（VideoToolbox，即時切換）· HDR 輸出（PQ + EDR）· ISO 光碟映像檔（藍光主標題、DVD 透過 EDL 無縫多段播放）· A-B 循環 · 變速播放 · 逐幀步進 · 章節
- **媒體伺服器** —— 直接瀏覽並播放 **WebDAV、SMB、FTP、Emby 和 Jellyfin** 上的內容；可排序的瀏覽器（名稱 / 修改時間 / 大小），資料夾一鍵加入播放清單
- **網路串流** —— HTTP(S) 直連連結和 m3u8/HLS，可調整預讀緩衝和 User-Agent
- **字幕** —— 自動載入同名字幕檔案、載入外部字幕、即時樣式調整（字體、大小、顏色、位置）
- **媒體庫與工具** —— 播放清單拖曳排序 · 帶斷點續播的歷史記錄 · 書籤 · 截圖 · 錄製 · 等化器 · 迷你懸浮窗
- **更多** —— 9 語言介面即時切換 · 手動檢查更新 · 零遙測

## 下載

最新安裝包見 [Releases](https://github.com/BrushLLM/brushllm-player/releases)：

| 平台 | 檔案 |
| --- | --- |
| macOS —— Apple Silicon（M 系列） | `.dmg`（arm64） |
| Windows 10/11 —— x64（Intel/AMD） | `.exe`（x64） |
| Windows 10/11 —— ARM64（Snapdragon） | `.exe`（arm64） |

> **應用程式未簽署。** macOS：首次啟動請右鍵選擇「開啟」（Gatekeeper）。Windows：遇到 SmartScreen 警告請選擇「仍要執行」—— 安裝器內建 9 語言選擇器並內建 mpv，無需額外下載。

## 授權

採用 GPL v3 授權（mpv / libmpv 授權條款）—— 見 [LICENSE](LICENSE)。

開發與架構詳情見 [English](README.md)。
