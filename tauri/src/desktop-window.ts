import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";

type VideoOutput = "embedded" | "detached" | "headless";
type ViewingMode = "windowed" | "fullscreen" | "mini";

export function useNativeVideoSurface(show: boolean, onError: (error: unknown) => void) {
  const stageRef = useRef<HTMLDivElement>(null);
  const [output, setOutput] = useState<VideoOutput>("headless");
  const placement = useRef(Promise.resolve());
  const placementRevision = useRef(0);

  useEffect(() => {
    if (!isTauri()) return;
    let cancelled = false;
    void invoke<VideoOutput>("video_output").then((value) => {
      if (!cancelled) setOutput(value);
    }).catch((error) => {
      if (!cancelled) onError(error);
    });
    return () => { cancelled = true; };
  }, [onError]);

  useLayoutEffect(() => {
    const stage = stageRef.current;
    if (output !== "embedded" || !stage) return;

    let frame: number | null = null;
    let previous = "";
    const update = () => {
      const ratio = window.devicePixelRatio;
      const { left, top, right, bottom } = stage.getBoundingClientRect();
      const bounds = {
        left: Math.round(left * ratio),
        top: Math.round(top * ratio),
        right: Math.round(right * ratio),
        bottom: Math.round(bottom * ratio),
      };
      const signature = JSON.stringify(bounds);
      if (signature !== previous) {
        previous = signature;
        const revision = ++placementRevision.current;
        // Skip queued placements superseded by newer geometry or visibility.
        placement.current = placement.current.then(async () => {
          if (revision === placementRevision.current) {
            await invoke("place_video_surface", { bounds, visible: show });
          }
        }).catch((error) => {
          if (revision === placementRevision.current) onError(error);
        });
      }
    };
    const schedule = () => {
      if (frame !== null) return;
      frame = requestAnimationFrame(() => {
        frame = null;
        update();
      });
    };
    const observer = new ResizeObserver(schedule);
    observer.observe(stage);
    window.addEventListener("resize", schedule);
    update();
    return () => {
      ++placementRevision.current;
      observer.disconnect();
      window.removeEventListener("resize", schedule);
      if (frame !== null) cancelAnimationFrame(frame);
    };
  }, [output, show, onError]);

  return { stageRef, output };
}

export function useViewingMode(onTop: boolean, onError: (error: unknown) => void) {
  const [mode, setMode] = useState<ViewingMode>("windowed");
  const changing = useRef(false);
  const observationRevision = useRef(0);

  useEffect(() => {
    if (!isTauri()) {
      const sync = () => {
        setMode((current) => document.fullscreenElement ? "fullscreen" : current === "mini" ? "mini" : "windowed");
      };
      document.addEventListener("fullscreenchange", sync);
      return () => document.removeEventListener("fullscreenchange", sync);
    }

    const desktop = getCurrentWindow();
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    let resizeProbe: ReturnType<typeof setTimeout> | undefined;
    const sync = async () => {
      if (changing.current) return;
      const sequence = ++observationRevision.current;
      const fullscreen = await desktop.isFullscreen();
      if (cancelled || changing.current || sequence !== observationRevision.current) return;
      setMode((current) => fullscreen ? "fullscreen" : current === "mini" ? "mini" : "windowed");
    };
    const syncFullscreen = () => { void sync().catch(() => {}); };
    const scheduleFullscreenSync = () => {
      clearTimeout(resizeProbe);
      // A resize burst only needs one fullscreen check. Commands update mode directly.
      resizeProbe = setTimeout(syncFullscreen, 100);
    };
    void desktop.onResized(scheduleFullscreenSync).then((stop) => {
      if (cancelled) stop();
      else unlisten = stop;
    }).catch(onError);
    syncFullscreen();
    return () => {
      cancelled = true;
      clearTimeout(resizeProbe);
      unlisten?.();
    };
  }, [onError]);

  const changeMode = useCallback(async (next: ViewingMode) => {
    if (changing.current) return;
    changing.current = true;
    ++observationRevision.current;
    try {
      if (isTauri()) {
        await invoke("set_viewing_mode", { mode: next, onTop });
      } else if (next === "fullscreen") {
        await document.documentElement.requestFullscreen();
      } else if (document.fullscreenElement) {
        await document.exitFullscreen();
      }
      setMode(next);
    } catch (error) {
      onError(error);
      if (isTauri()) {
        const actual = await getCurrentWindow().isFullscreen().catch(() => null);
        if (actual !== null) {
          setMode((current) => actual ? "fullscreen" : current === "fullscreen" ? "windowed" : current);
        }
      }
    } finally {
      changing.current = false;
    }
  }, [onTop, onError]);

  return { mode, changeMode };
}
