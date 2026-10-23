# BrushLLM Player

[English](../README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

mpv 기반의 오픈소스 크로스 플랫폼 미디어 플레이어입니다. 거의 모든 형식을 재생하고, WebDAV / SMB / FTP / Emby / Jellyfin에서 직접 스트리밍할 수 있으며, 9개 언어 UI를 제공합니다.

## 기능

- **재생** — mpv가 지원하는 거의 모든 형식(MKV, MP4, AVI, MOV, WebM, FLAC, MP3 등) · 하드웨어 디코딩(VideoToolbox, 실시간 전환) · HDR 출력(PQ + EDR) · ISO 디스크 이미지(블루레이 메인 타이틀, DVD는 EDL로 끊김 없이) · A-B 루프 · 배속 재생 · 프레임 단위 이동 · 챕터
- **미디어 서버** — **WebDAV, SMB, FTP, Emby, Jellyfin**을 직접 탐색하고 재생. 정렬 가능한 브라우저(이름 / 수정일 / 크기)와 폴더→재생목록 추가
- **네트워크 스트림** — HTTP(S) 직접 링크와 m3u8/HLS, 조절 가능한 미리 읽기 버퍼와 User-Agent
- **자막** — 일치하는 파일 자동 불러오기, 외부 자막, 실시간 스타일 조정(글꼴, 크기, 색상, 위치)
- **라이브러리와 도구** — 드래그로 순서 변경하는 재생목록 · 이어보기 기록 · 북마크 · 스크린샷 · 녹화 · 이퀄라이저 · 미니 창
- **기타** — 9개 언어 UI 즉시 전환 · 수동 업데이트 확인 · 텔레메트리 없음

## 다운로드

최신 설치 파일은 [Releases](https://github.com/BrushLLM/brushllm-player/releases)에서:

| 플랫폼 | 파일 |
| --- | --- |
| macOS — Apple Silicon(M 시리즈) | `.dmg` (arm64) |
| Windows 10/11 — x64(Intel/AMD) | `.exe` (x64) |
| Windows 10/11 — ARM64(Snapdragon) | `.exe` (arm64) |

> **앱은 서명되지 않았습니다.** macOS: 첫 실행 시 앱을 마우스 오른쪽 클릭으로 *열기*를 선택하세요(Gatekeeper). Windows: SmartScreen 경고가 나타나면 *실행*을 선택하세요 — 설치 프로그램은 9개 언어 선택기와 함께 열리고 mpv를 포함하고 있어 추가 다운로드가 필요 없습니다.

## 라이선스

GPL v3 라이선스(mpv / libmpv 라이선스) — [LICENSE](../LICENSE)를 참조하세요.

개발 및 아키텍처 세부 사항은 [English](../README.md)를 참조하세요.
