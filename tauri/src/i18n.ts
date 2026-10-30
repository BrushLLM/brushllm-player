// In-app localization, ported from the mac Localization.swift: string tables
// are statically bundled (no lazy loading, no file access), an explicit
// override redirects lookups to that table, and "system" resolves the
// browser's preferred languages with the same matching ladder as the mac
// side (exact regional match -> Chinese script detection -> base language ->
// prefix match -> English fallback).
//
// React integration: a tiny module-level store (current language + listener
// set) so every component can call useI18n() independently and still see the
// same language. setLang persists to localStorage ("brushplayer.language")
// and notifies all subscribers; useSyncExternalStore makes each subscribed
// component re-render, and since t() runs at render time the whole UI
// switches language immediately.

import { useCallback, useSyncExternalStore } from "react";

import enJson from "./i18n/en.json";
import deJson from "./i18n/de.json";
import esJson from "./i18n/es.json";
import frJson from "./i18n/fr.json";
import ptBRJson from "./i18n/pt-BR.json";
import jaJson from "./i18n/ja.json";
import zhHansJson from "./i18n/zh-Hans.json";
import zhHantJson from "./i18n/zh-Hant.json";
import koJson from "./i18n/ko.json";

export type LanguageCode =
  | "system"
  | "en"
  | "de"
  | "es"
  | "fr"
  | "pt-BR"
  | "ja"
  | "zh-Hans"
  | "zh-Hant"
  | "ko";

// resolveJsonModule infers a literal key union per file; widening to
// Record<string, string> keeps t()'s dynamic lookups type-safe.
const en: Record<string, string> = enJson;
const TABLES: Record<string, Record<string, string>> = {
  en,
  de: deJson,
  es: esJson,
  fr: frJson,
  "pt-BR": ptBRJson,
  ja: jaJson,
  "zh-Hans": zhHansJson,
  "zh-Hant": zhHantJson,
  ko: koJson,
};

/** Endonyms, same as the mac LanguageOption.endonyms map. */
const ENDONYMS: Record<string, string> = {
  en: "English",
  de: "Deutsch",
  es: "Español",
  fr: "Français",
  "pt-BR": "Português (Brasil)",
  ja: "日本語",
  "zh-Hans": "简体中文",
  "zh-Hant": "繁體中文",
  ko: "한국어",
};

/**
 * The shipped languages in the mac order. The "system" entry's label is
 * resolved through t() at render time (settings.language.system); the rest
 * use their endonym, which never needs translation.
 */
export const LANGUAGES: { code: LanguageCode; label: string }[] = [
  { code: "system", label: "System Language" },
  { code: "en", label: ENDONYMS.en },
  { code: "de", label: ENDONYMS.de },
  { code: "es", label: ENDONYMS.es },
  { code: "fr", label: ENDONYMS.fr },
  { code: "pt-BR", label: ENDONYMS["pt-BR"] },
  { code: "ja", label: ENDONYMS.ja },
  { code: "zh-Hans", label: ENDONYMS["zh-Hans"] },
  { code: "zh-Hant", label: ENDONYMS["zh-Hant"] },
  { code: "ko", label: ENDONYMS.ko },
];

const STORAGE_KEY = "brushplayer.language";

function isLanguageCode(value: string): value is LanguageCode {
  return value === "system" || Object.prototype.hasOwnProperty.call(TABLES, value);
}

function storedLanguage(): LanguageCode {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    if (stored !== null && isLanguageCode(stored)) return stored;
  } catch {
    // localStorage can throw in sandboxed webviews; "system" is the default.
  }
  return "system";
}

/**
 * Picks the best shipped language from a list of BCP-47 tags, mirroring the
 * mac systemLanguageCode ladder:
 *   1. exact two-part regional match ("pt-BR", "zh-Hans")
 *   2. Chinese script detection (Hant/TW/HK/MO -> zh-Hant, else zh-Hans)
 *   3. base language match ("en-US" -> "en", "pt-PT" -> "pt-BR")
 *   4. any shipped language with that base as prefix
 *   5. "en"
 * Pure function: the preferred list is a parameter so tests can drive it
 * without a DOM; the no-arg form reads the browser preferences.
 */
export function resolveSystemLanguage(preferred?: string[]): string {
  const tags = preferred ?? (typeof navigator !== "undefined" ? navigator.languages ?? [navigator.language] : []);
  const available = new Set(Object.keys(TABLES));
  for (const tag of tags) {
    if (!tag) continue;
    // Tag forms: "zh-Hans-CN", "pt-BR", "en-US", "de-DE", …
    const parts = tag.split("-");
    const base = parts[0];
    if (!base) continue;

    // Exact regional match first ("pt-BR", "zh-Hans").
    if (parts.length > 1) {
      const twoPart = `${base}-${parts[1]}`;
      if (available.has(twoPart)) return twoPart;
    }

    // Chinese: pick the script from the tag; default to Simplified.
    if (base.toLowerCase() === "zh") {
      const lower = tag.toLowerCase();
      if (lower.includes("hant") || lower.includes("tw") || lower.includes("hk") || lower.includes("mo")) {
        if (available.has("zh-Hant")) return "zh-Hant";
      }
      if (available.has("zh-Hans")) return "zh-Hans";
    }

    // Base language match ("en-US" -> "en", "pt-PT" -> "pt-BR").
    if (available.has(base)) return base;
    for (const candidate of available) {
      if (candidate.startsWith(`${base}-`)) return candidate;
    }
  }
  return "en";
}

/**
 * Looks up `key` in the table for `lang` ("system" resolves through the
 * browser preferences). Falls back to the English table, then to the key
 * itself so a missing translation never renders an empty string.
 */
export function t(key: string, lang: LanguageCode): string {
  const resolved = lang === "system" ? resolveSystemLanguage() : lang;
  return TABLES[resolved]?.[key] ?? en[key] ?? key;
}

// --- Language store (module-level singleton shared by every useI18n call) ---

let currentLang: LanguageCode = typeof window !== "undefined" ? storedLanguage() : "system";
const listeners = new Set<() => void>();

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** The store snapshot for useSyncExternalStore: the language itself. */
function getSnapshot(): LanguageCode {
  return currentLang;
}

/** Server/SSR snapshot — this app is purely client-side, so "system". */
function getServerSnapshot(): LanguageCode {
  return "system";
}

function setLang(lang: LanguageCode): void {
  if (lang === currentLang) return;
  currentLang = lang;
  try {
    window.localStorage.setItem(STORAGE_KEY, lang);
  } catch {
    // Persistence is best-effort; the in-memory switch still applies.
  }
  for (const listener of listeners) listener();
}

/**
 * Per-component i18n hook. Every component that calls this subscribes to the
 * shared language store, so a setLang in the settings panel re-renders the
 * whole UI at once. `t` closes over the current language.
 */
export function useI18n(): { t: (key: string) => string; lang: LanguageCode; setLang: (l: LanguageCode) => void } {
  const lang = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const translate = useCallback((key: string) => t(key, lang), [lang]);
  return { t: translate, lang, setLang };
}

/** Label for a language entry: the localized "System Language" for "system",
 *  the endonym otherwise. Used by the settings dropdown. */
export function languageLabel(code: LanguageCode, translate: (key: string) => string): string {
  return code === "system" ? translate("settings.language.system") : ENDONYMS[code] ?? code;
}
