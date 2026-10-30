// Add/edit server form, ported from the mac AddServerForm: five kind
// capsules, kind-adaptive fields (webdav: title/protocol/host/port/path/
// user/password; smb: title/host/share/user/password; ftp: title/host/port/
// path/user/password; emby+jellyfin: title/protocol/host/port/user/password),
// a password-storage hint, a live composed-URL preview and save/cancel.
// Saving calls the Rust servers_add / servers_update commands; on success the
// parent receives the saved source (mac behavior: connect immediately).

import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";

import { useI18n } from "../../i18n";
import type { ServerKind, ServerSource } from "../../server-state";
import {
  composeBaseUrl,
  formFieldsFromSource,
  requiredFieldsFilled,
  serverDisplayName,
  type ServerFormFields,
} from "../../server-state";
import { commandError } from "../../player-state";

const KINDS: ServerKind[] = ["webdav", "smb", "ftp", "emby", "jellyfin"];

function placeholderHost(kind: ServerKind): string {
  switch (kind) {
    case "webdav": return "cloud.example.com";
    case "smb": return "192.168.1.10";
    case "ftp": return "ftp.example.com";
    case "emby":
    case "jellyfin": return "media.example.com";
  }
}

function placeholderPort(kind: ServerKind, scheme: "https" | "http"): string {
  switch (kind) {
    case "webdav": return scheme === "https" ? "443" : "80";
    case "ftp": return "21";
    default: return "8096";
  }
}

export interface AddServerFormProps {
  /** When set, the form edits this server (pre-filled, servers_update);
   *  otherwise it adds (servers_add). */
  editing: ServerSource | null;
  onSaved: (server: ServerSource) => void;
  onCancel: () => void;
}

export default function AddServerForm({ editing, onSaved, onCancel }: AddServerFormProps) {
  const { t } = useI18n();
  const [fields, setFields] = useState<ServerFormFields>(() =>
    editing !== null ? formFieldsFromSource(editing) : { kind: "webdav", name: "", scheme: "https", host: "", port: "", path: "", username: "", password: "" },
  );
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const set = <K extends keyof ServerFormFields>(key: K, value: ServerFormFields[K]) => {
    setFields((current) => ({ ...current, [key]: value }));
  };

  const composedUrl = composeBaseUrl(fields);
  const canSave = requiredFieldsFilled(fields) && !saving;

  const save = () => {
    if (!canSave) return;
    setSaving(true);
    setSaveError(null);
    const baseUrl = composeBaseUrl(fields);
    const name = serverDisplayName(fields);
    const finish = () => setSaving(false);
    if (editing !== null) {
      // servers_update: an empty password keeps the stored one (the edit form
      // does not echo it back).
      const source: ServerSource = { ...editing, kind: fields.kind, name, baseUrl, username: fields.username };
      void invoke<boolean>("servers_update", { source, password: fields.password === "" ? null : fields.password })
        .then(() => {
          finish();
          onSaved({ ...source, password: fields.password });
        })
        .catch((error) => {
          finish();
          setSaveError(commandError(error).message);
        });
    } else {
      void invoke<ServerSource>("servers_add", {
        kind: fields.kind, name, baseUrl, username: fields.username, password: fields.password,
      })
        .then((server) => {
          finish();
          onSaved(server);
        })
        .catch((error) => {
          finish();
          setSaveError(commandError(error).message);
        });
    }
  };

  const showScheme = fields.kind === "webdav" || fields.kind === "emby" || fields.kind === "jellyfin";
  const showPort = fields.kind !== "smb";
  const showPath = fields.kind === "webdav" || fields.kind === "ftp" || fields.kind === "smb";

  return (
    <form
      className="net-form"
      onSubmit={(event) => {
        event.preventDefault();
        save();
      }}
    >
      <div className="net-kind-picker" role="radiogroup" aria-label={t("webdav.select")}>
        {KINDS.map((kind) => (
          <button
            key={kind}
            type="button"
            role="radio"
            aria-checked={fields.kind === kind}
            className={`net-kind-chip ${fields.kind === kind ? "active" : ""}`}
            onClick={() => set("kind", kind)}
          >
            {kind.toUpperCase()}
          </button>
        ))}
      </div>

      <label className="net-field">
        <span className="net-field-label">{t("webdav.title")}</span>
        <input className="net-field-input" type="text" value={fields.name}
          onChange={(event) => set("name", event.target.value)} placeholder="NAS" spellCheck={false} />
      </label>

      {showScheme && (
        <div className="net-field">
          <span className="net-field-label">{t("webdav.scheme")}</span>
          <div className="net-scheme-toggle" role="radiogroup" aria-label={t("webdav.scheme")}>
            {(["https", "http"] as const).map((scheme) => (
              <button
                key={scheme}
                type="button"
                role="radio"
                aria-checked={fields.scheme === scheme}
                className={`net-scheme-option ${fields.scheme === scheme ? "active" : ""}`}
                onClick={() => set("scheme", scheme)}
              >
                {scheme}
              </button>
            ))}
          </div>
        </div>
      )}

      <label className="net-field">
        <span className="net-field-label">{t("webdav.host")}</span>
        <input className="net-field-input" type="text" value={fields.host}
          onChange={(event) => set("host", event.target.value)}
          placeholder={placeholderHost(fields.kind)} spellCheck={false} autoFocus={editing === null} />
      </label>

      {showPort && (
        <label className="net-field">
          <span className="net-field-label">{t("webdav.port")}</span>
          <input className="net-field-input" type="text" value={fields.port}
            onChange={(event) => set("port", event.target.value)}
            placeholder={placeholderPort(fields.kind, fields.scheme)} spellCheck={false} inputMode="numeric" />
        </label>
      )}

      {showPath && (
        <label className="net-field">
          <span className="net-field-label">{fields.kind === "smb" ? t("webdav.share") : t("webdav.path")}</span>
          <input className="net-field-input" type="text" value={fields.path}
            onChange={(event) => set("path", event.target.value)}
            placeholder={fields.kind === "smb" ? "media" : "/dav"} spellCheck={false} />
        </label>
      )}

      <label className="net-field">
        <span className="net-field-label">{t("webdav.username")}</span>
        <input className="net-field-input" type="text" value={fields.username}
          onChange={(event) => set("username", event.target.value)} spellCheck={false} autoComplete="off" />
      </label>
      <label className="net-field">
        <span className="net-field-label">{t("webdav.password")}</span>
        <input className="net-field-input" type="password" value={fields.password}
          onChange={(event) => set("password", event.target.value)} spellCheck={false} autoComplete="new-password" />
      </label>
      {/* Windows port: passwords live in the per-user servers.json config
          file, not a Keychain — new key, reported for the 9-language batch. */}
      <p className="net-form-hint">{t("webdav.password-local")}</p>

      {fields.host.trim() !== "" && (
        <p className="net-url-preview" title={composedUrl}>{composedUrl}</p>
      )}

      {saveError !== null && <p className="net-form-error" role="alert">{saveError}</p>}

      <div className="net-form-actions">
        <button type="button" className="net-form-cancel" onClick={onCancel}>
          {t("panel.cancel")}
        </button>
        <button type="submit" className="net-form-save" disabled={!canSave}>
          {editing === null ? t("webdav.connect") : t("webdav.save")}
        </button>
      </div>
    </form>
  );
}
