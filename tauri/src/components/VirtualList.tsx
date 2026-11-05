import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import { listWindow } from "../virtual-list";

interface Props<T> {
  items: T[];
  itemKey: (item: T) => string;
  renderItem: (item: T) => ReactNode;
  isFocusable: (item: T) => boolean;
}

/** Fixed-height media rows with overscan and arrow-key access to offscreen rows. */
export default function VirtualList<T>({ items, itemKey, renderItem, isFocusable }: Props<T>) {
  const container = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState({ top: 0, height: 500 });
  const rowHeight = 34;
  const { start, end } = listWindow(items.length, viewport.top, viewport.height, rowHeight);

  useEffect(() => {
    const element = container.current;
    if (!element) return;
    const update = () => setViewport({ top: element.scrollTop, height: element.clientHeight });
    const observer = new ResizeObserver(update);
    observer.observe(element);
    update();
    return () => observer.disconnect();
  }, []);

  return (
    <div className="net-browser-list" role="list" ref={container}
      onScroll={(event) => setViewport({ top: event.currentTarget.scrollTop, height: event.currentTarget.clientHeight })}
      onKeyDown={(event) => {
        if (event.ctrlKey || event.metaKey || event.altKey || !["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
        const element = container.current;
        const row = event.target instanceof HTMLElement ? event.target.closest<HTMLElement>("[data-row-index]") : null;
        if (!element || !row) return;
        const direction = event.key === "ArrowUp" || event.key === "End" ? -1 : 1;
        let index = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 : Number(row.dataset.rowIndex) + direction;
        while (index >= 0 && index < items.length && !isFocusable(items[index])) index += direction;
        if (index < 0 || index >= items.length) return;
        event.preventDefault();
        event.stopPropagation();
        const top = index * rowHeight;
        if (top < element.scrollTop) element.scrollTop = top;
        else if (top + rowHeight > element.scrollTop + element.clientHeight) element.scrollTop = top + rowHeight - element.clientHeight;
        setViewport({ top: element.scrollTop, height: element.clientHeight });
        requestAnimationFrame(() => element.querySelector<HTMLButtonElement>(`[data-row-index="${index}"] button`)?.focus());
      }}>
      <div style={{ height: items.length * rowHeight, position: "relative" }}>
        {items.slice(start, end).map((item, offset) => (
          <div key={itemKey(item)} role="listitem" aria-posinset={start + offset + 1} aria-setsize={items.length}
            data-row-index={start + offset}
            style={{ position: "absolute", top: (start + offset) * rowHeight, height: rowHeight, width: "100%" }}>
            {renderItem(item)}
          </div>
        ))}
      </div>
    </div>
  );
}
