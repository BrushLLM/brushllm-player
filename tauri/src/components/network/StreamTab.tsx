// Stream tab of the network panel, a simplified port of the mac StreamTab:
// a centered URL input + play action and a paste-from-clipboard capsule.
// The mac version's collapsed "Advanced" section (User-Agent / read-ahead /
// buffer sliders) is intentionally omitted for V1 — the Rust backend exposes
// no per-request UA or buffer settings, so the controls would be decorative.

import { useState } from "react";

import { useI18n } from "../../i18n";

export interface StreamTabProps {
  onPlay: (url: string) => void;
}

export default function StreamTab({ onPlay }: StreamTabProps) {
  const { t } = useI18n();
  const [urlText, setUrlText] = useState("");

  const trimmed = urlText.trim();
  const play = () => {
    if (trimmed === "") return;
    // IINA OpenURLWindowController: default a missing scheme to http://.
    const url = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed) ? trimmed : `http://${trimmed}`;
    setUrlText("");
    onPlay(url);
  };

  const pasteFromClipboard = () => {
    void navigator.clipboard
      .readText()
      .then((text) => {
        const value = text.trim();
        if (value !== "") setUrlText(value);
      })
      .catch(() => {
        // Clipboard permission denied or empty — silently keep the field.
      });
  };

  return (
    <div className="net-stream">
      <div className="net-stream-hero">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M4 13 Q4 4 12 4 Q20 4 20 13" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          <path d="M20 13 Q20 22 12 22 Q4 22 4 13" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
          <circle cx="12" cy="13" r="2.2" fill="currentColor" />
        </svg>
        <div className="net-stream-title">{t("network.tab.url")}</div>
      </div>

      <form
        className="net-stream-form"
        onSubmit={(event) => {
          event.preventDefault();
          play();
        }}
      >
        <input
          className="net-stream-input"
          type="text"
          value={urlText}
          onChange={(event) => setUrlText(event.target.value)}
          placeholder={t("panel.url.hint")}
          autoFocus
          spellCheck={false}
        />
        <button className="net-stream-play" type="submit" disabled={trimmed === ""}>
          {t("panel.url.open")}
        </button>
      </form>

      <button type="button" className="net-stream-paste" onClick={pasteFromClipboard}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="6" y="5" width="12" height="16" rx="2" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <path d="M9 5 V3.5 H15 V5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
          <path d="M9.5 11 H14.5 M9.5 14.5 H14.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        {t("network.paste")}
      </button>
    </div>
  );
}
