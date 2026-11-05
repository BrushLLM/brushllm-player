/** Bound rendered rows by viewport size, regardless of the directory size. */
export function listWindow(count: number, top: number, height: number, rowHeight: number, overscan = 6) {
  const safeTop = Number.isFinite(top) ? Math.max(0, top) : 0;
  const safeHeight = Number.isFinite(height) ? Math.max(rowHeight, height) : rowHeight;
  const start = Math.min(count, Math.max(0, Math.floor(safeTop / rowHeight) - overscan));
  const end = Math.min(count, Math.ceil((safeTop + safeHeight) / rowHeight) + overscan);
  return { start, end: Math.max(start, end) };
}
