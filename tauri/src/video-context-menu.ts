import { useCallback, useEffect, useRef } from "react";
import { isTauri, type Resource } from "@tauri-apps/api/core";
import type { LogicalPosition, PhysicalPosition } from "@tauri-apps/api/dpi";
import { CheckMenuItem, Menu, Submenu } from "@tauri-apps/api/menu";
import { formatPlaybackRate, playbackSpeedPresets } from "./playback-speed";

async function createSpeedMenu(title: string, selectSpeed: (value: string) => void) {
  const resources: Resource[] = [];
  const close = async () => {
    for (const resource of resources.splice(0).reverse()) {
      await resource.close().catch(() => {});
    }
  };

  try {
    const items: CheckMenuItem[] = [];
    for (const rate of playbackSpeedPresets) {
      const item = await CheckMenuItem.new({
        text: formatPlaybackRate(rate),
        checked: false,
        action: () => selectSpeed(String(rate)),
      });
      items.push(item);
      resources.push(item);
    }
    // Retain the item handles so native selections keep their action callbacks.
    const submenu = await Submenu.new({ text: title, items });
    resources.push(submenu);
    const menu = await Menu.new({ items: [submenu] });
    resources.push(menu);
    return { menu, submenu, items, close };
  } catch (error) {
    await close();
    throw error;
  }
}

export function useVideoSpeedMenu(selectSpeed: (value: string) => void, reportError: (error: unknown) => void) {
  const menuRef = useRef<ReturnType<typeof createSpeedMenu> | null>(null);
  const open = useRef(false);

  useEffect(() => () => {
    void menuRef.current?.then((menu) => menu.close(), () => {});
    menuRef.current = null;
  }, []);

  return useCallback(async (
    title: string, speed: number, position?: LogicalPosition | PhysicalPosition,
  ) => {
    if (!isTauri() || open.current) return;
    open.current = true;
    const pending = menuRef.current ??= createSpeedMenu(title, selectSpeed);
    try {
      const { menu, submenu, items } = await pending;
      if (menuRef.current !== pending) return;
      await Promise.all([
        submenu.setText(title),
        ...items.map((item, index) => item.setChecked(playbackSpeedPresets[index] === speed)),
      ]);
      if (menuRef.current === pending) await menu.popup(position);
    } catch (error) {
      if (menuRef.current === pending) {
        menuRef.current = null;
        void pending.then((menu) => menu.close(), () => {});
        reportError(error);
      }
    } finally {
      open.current = false;
    }
  }, [reportError, selectSpeed]);
}
