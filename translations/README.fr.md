# BrushLLM Player

[English](../README.md) | [Deutsch](README.de.md) | [Español](README.es.md) | [Français](README.fr.md) | [Português (BR)](README.pt-BR.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md)

Un lecteur multimédia open source basé sur mpv — lit pratiquement tous les formats, diffuse depuis WebDAV / SMB / FTP / Emby / Jellyfin et propose une interface en 9 langues.

## Fonctions

- **Lecture** — presque tous les formats pris en charge par mpv (MKV, MP4, AVI, MOV, WebM, FLAC, MP3, …) · décodage matériel (VideoToolbox, bascule en direct) · sortie HDR (PQ + EDR) · images disque ISO (titre principal Blu-ray, DVD sans coupure via EDL) · boucle A-B · vitesse · pas à pas image · chapitres
- **Serveurs multimédias** — parcourt et lit directement depuis **WebDAV, SMB, FTP, Emby et Jellyfin** ; navigateur triable (nom / modification / taille) et dossier-vers-liste-de-lecture
- **Flux réseau** — liens directs HTTP(S) et m3u8/HLS, avec tampon de lecture anticipée et User-Agent réglables
- **Sous-titres** — chargement automatique des fichiers correspondants, sous-titres externes, style en direct (police, taille, couleur, position)
- **Bibliothèque et outils** — liste de lecture réorganisable par glisser-déposer · historique avec reprise · favoris · captures · enregistrements · égaliseur · mini-fenêtre
- **Aussi** — interface en 9 langues à changement instantané · vérification manuelle des mises à jour · aucune télémétrie

## Téléchargement

Installateurs actuels sur [Releases](https://github.com/BrushLLM/brushllm-player/releases) :

| Plateforme | Fichier |
| --- | --- |
| macOS — Apple Silicon (série M) | `.dmg` (arm64) |
| Windows 10/11 — x64 (Intel/AMD) | `.exe` (x64) |
| Windows 10/11 — ARM64 (Snapdragon) | `.exe` (arm64) |

> **Les apps ne sont pas signées.** macOS : au premier lancement, clic droit sur l'app puis *Ouvrir* (Gatekeeper). Windows : choisir *Exécuter quand même* à l'apparition de SmartScreen — l'installateur s'ouvre avec un sélecteur de 9 langues et inclut mpv, sans téléchargements supplémentaires.

## Licence

Sous licence GPL v3 (licences mpv / libmpv) — voir [LICENSE](../LICENSE).

Développement et architecture : voir [English](../README.md).
