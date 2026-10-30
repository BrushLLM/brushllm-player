// Settings modal, ported from the mac GeneralSettingsTab's Language and
// About sections: a language picker (immediate effect — the shared i18n store
// re-renders every subscribed component), a manual check-for-updates card
// (GitHub releases API, no automatic checks or downloads by design) and the
// About block (version, GPL v3 line, project links). Reuses the About
// dialog's overlay/dialog chrome (.about-overlay/.about-dialog) with the
// same Escape/outside-click dismissal and focus trap as App's About dialog.

import { useCallback, useEffect, useRef, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { openUrl as openExternal } from "@tauri-apps/plugin-opener";

import { LANGUAGES, languageLabel, useI18n } from "../i18n";
import type { LanguageCode } from "../i18n";

const GITHUB_API_LATEST = "https://api.github.com/repos/BrushLLM/brushllm-player/releases/latest";
const GITHUB_RELEASES_URL = "https://github.com/BrushLLM/brushllm-player/releases";

export interface SettingsPanelProps {
  onClose: () => void;
}

type UpdateState =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "up-to-date" }
  | { kind: "available"; latest: string }
  | { kind: "failed" };

/** Numeric dotted-version comparison — "0.0.10" > "0.0.9". Missing segments
 *  count as zero (same as the mac UpdateChecker.compare). */
function isNewerVersion(latest: string, current: string): boolean {
  const a = latest.replace(/^v/, "").split(".").map((part) => Number.parseInt(part, 10) || 0);
  const b = current.replace(/^v/, "").split(".").map((part) => Number.parseInt(part, 10) || 0);
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i++) {
    const x = i < a.length ? a[i] : 0;
    const y = i < b.length ? b[i] : 0;
    if (x > y) return true;
    if (x < y) return false;
  }
  return false;
}

export default function SettingsPanel({ onClose }: SettingsPanelProps) {
  const { t, lang, setLang } = useI18n();
  const [updateState, setUpdateState] = useState<UpdateState>({ kind: "idle" });
  const [appVersion, setAppVersion] = useState<string | null>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    let cancelled = false;
    void getVersion()
      .then((version) => { if (!cancelled) setAppVersion(version || "Unavailable"); })
      .catch(() => { if (!cancelled) setAppVersion("Unavailable"); });
    return () => { cancelled = true; };
  }, []);

  const checkForUpdates = useCallback(async () => {
    setUpdateState({ kind: "checking" });
    try {
      const response = await fetch(GITHUB_API_LATEST, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const release = (await response.json()) as { tag_name?: string };
      const tag = typeof release.tag_name === "string" ? release.tag_name : "";
      if (!tag) throw new Error("invalid response body");
      const latest = tag.startsWith("v") ? tag.slice(1) : tag;
      const current = (appVersion ?? "").replace(/^v/, "");
      setUpdateState(isNewerVersion(latest, current) ? { kind: "available", latest } : { kind: "up-to-date" });
    } catch {
      setUpdateState({ kind: "failed" });
    }
  }, [appVersion]);

  // Escape / Tab focus trap / outside-click dismissal, same pattern as the
  // About dialog in App.tsx.
  useEffect(() => {
    const previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
        return;
      }
      if (event.key === "Tab") {
        const focusable = dialogRef.current?.querySelectorAll<HTMLElement>(
          "button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])",
        );
        if (!focusable?.length) return;
        const items = Array.from(focusable);
        const current = document.activeElement as HTMLElement | null;
        const index = current ? items.indexOf(current) : -1;
        const next = event.shiftKey
          ? (index <= 0 ? items.length - 1 : index - 1)
          : (index === -1 || index === items.length - 1 ? 0 : index + 1);
        event.preventDefault();
        items[next].focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    closeRef.current?.focus();
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      if (previouslyFocused?.isConnected) previouslyFocused.focus();
    };
  }, [onClose]);

  return (
    <div
      className="about-overlay"
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <section
        id="settings-dialog"
        className="about-dialog settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-dialog-title"
      >
        <div className="about-header">
          <h2 id="settings-dialog-title">{t("settings.general")}</h2>
          <button
            ref={closeRef}
            className="tool-btn about-close"
            onClick={onClose}
            aria-label={t("panel.cancel")}
            title={t("panel.cancel")}
            autoFocus
          >
            <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <line x1="6" y1="6" x2="18" y2="18" />
              <line x1="18" y1="6" x2="6" y2="18" />
            </svg>
          </button>
        </div>

        <div className="settings-section">
          <div className="settings-section-title">{t("settings.general.language")}</div>
          <select
            className="settings-language-select"
            value={lang}
            aria-label={t("settings.general.language")}
            onChange={(event) => setLang(event.target.value as LanguageCode)}
          >
            {LANGUAGES.map(({ code }) => (
              <option key={code} value={code}>{languageLabel(code, t)}</option>
            ))}
          </select>
          <p className="settings-hint">{t("settings.general.language-note")}</p>
        </div>

        <div className="settings-section">
          <div className="settings-section-title">{t("settings.about")}</div>
          <p className="settings-version">
            {t("update.current")} v{appVersion ?? "…"}
          </p>
          <button
            type="button"
            className="settings-update-btn"
            onClick={() => void checkForUpdates()}
            disabled={updateState.kind === "checking"}
          >
            {t("update.check")}
          </button>
          <div className="settings-update-status" role="status">
            {updateState.kind === "checking" && (
              <span className="settings-update-note">
                <span className="settings-spinner" aria-hidden="true" />
                {t("update.checking")}
              </span>
            )}
            {updateState.kind === "up-to-date" && (
              <span className="settings-update-note ok">{t("update.up-to-date")}</span>
            )}
            {updateState.kind === "available" && (
              <span className="settings-update-note new">
                {t("update.available")} v{updateState.latest}
                <button
                  type="button"
                  className="settings-update-download"
                  onClick={() => void openExternal(GITHUB_RELEASES_URL)}
                >
                  {t("update.download")}
                </button>
              </span>
            )}
            {updateState.kind === "failed" && (
              <span className="settings-update-note failed">{t("update.failed")}</span>
            )}
          </div>
          <p className="settings-hint">{t("about.license")}</p>
          <div className="about-links" aria-label={t("about.github")}>
            <button className="about-link" type="button" onClick={() => void openExternal("https://github.com/BrushLLM/brushllm-player")}>
              {t("about.github")}
              <span aria-hidden="true">↗</span>
            </button>
            <button className="about-link" type="button" onClick={() => void openExternal(GITHUB_RELEASES_URL)}>
              {t("about.releases")}
              <span aria-hidden="true">↗</span>
            </button>
            <button className="about-link" type="button" onClick={() => void openExternal("https://github.com/BrushLLM/brushllm-player/blob/main/LICENSE")}>
              {t("about.license-link")}
              <span aria-hidden="true">↗</span>
            </button>
          </div>
        </div>
      </section>
    </div>
  );
}
