# BrushLLM Player

[English](README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

一个基于 mpv 的开源跨平台媒体播放器 —— 支持几乎所有格式，可从 WebDAV / SMB / FTP / Emby / Jellyfin 流媒体服务器直接播放，内置 9 语言界面。

## 功能

- **播放** —— mpv 支持的几乎所有格式（MKV、MP4、AVI、MOV、WebM、FLAC、MP3 等）· 硬件解码（VideoToolbox，实时切换）· HDR 输出（PQ + EDR）· ISO 光盘镜像（蓝光主标题、DVD 通过 EDL 无缝多段播放）· A-B 循环 · 变速播放 · 逐帧步进 · 章节
- **媒体服务器** —— 直接浏览并播放 **WebDAV、SMB、FTP、Emby 和 Jellyfin** 上的内容；可排序的浏览器（名称 / 修改时间 / 大小），文件夹一键加入播放列表
- **网络流** —— HTTP(S) 直链和 m3u8/HLS，可调节预读缓冲和 User-Agent
- **字幕** —— 自动加载同名字幕文件、加载外部字幕、实时样式调整（字体、大小、颜色、位置）
- **库与工具** —— 播放列表拖拽排序 · 带断点续播的历史记录 · 书签 · 截图 · 录制 · 均衡器 · 迷你悬浮窗
- **更多** —— 9 语言界面即时切换 · 手动检查更新 · 零遥测

## 下载

最新安装包见 [Releases](https://github.com/BrushLLM/brushllm-player/releases)：

| 平台 | 文件 |
| --- | --- |
| macOS —— Apple Silicon（M 系列） | `.dmg`（arm64） |
| Windows 10/11 —— x64（Intel/AMD） | `.exe`（x64） |
| Windows 10/11 —— ARM64（Snapdragon） | `.exe`（arm64） |

> **应用未签名。** macOS：首次启动请右键选择“打开”（Gatekeeper）。Windows：遇到 SmartScreen 警告请选择“仍要运行” —— 安装器自带 9 语言选择器并内置 mpv，无需额外下载。

## 许可

采用 GPL v3 许可（mpv / libmpv 许可条款）—— 见 [LICENSE](LICENSE)。

开发与架构详情见 [English](README.md)。
