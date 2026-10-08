// Erasing part of a stroke and selecting strokes with the lasso,
// like `Stroke.erasedAround` and `Select` in the app.

import { Stroke, Tools, newId } from './model.js';
import { boundsOf, pathOf } from './render.js';

function sqrDistanceToSegment(px, py, ax, ay, bx, by) {
  const abx = bx - ax;
  const aby = by - ay;
  const lengthSquared = abx * abx + aby * aby;
  if (lengthSquared === 0) return (px - ax) ** 2 + (py - ay) ** 2;
  const t = Math.max(0, Math.min(1, ((px - ax) * abx + (py - ay) * aby) / lengthSquared));
  return (px - (ax + abx * t)) ** 2 + (py - (ay + aby * t)) ** 2;
}

function pointsBounds(points) {
  let left = Infinity;
  let top = Infinity;
  let right = -Infinity;
  let bottom = -Infinity;
  for (const [x, y] of points) {
    left = Math.min(left, x);
    right = Math.max(right, x);
    top = Math.min(top, y);
    bottom = Math.max(bottom, y);
  }
  return { left, top, right, bottom };
}

/**
 * Returns what's left of `stroke` after erasing the circle of `radius`
 * around (cx, cy): new strokes for the pieces on either side, or null if the
 * circle doesn't touch it. Shapes and dots are erased whole.
 */
export function erasedAround(stroke, cx, cy, radius) {
  const reach = radius + stroke.options.s / 2;
  const sqrReach = reach * reach;
  const b = boundsOf(stroke);
  if (cx < b.left - reach || cx > b.right + reach || cy < b.top - reach || cy > b.bottom + reach) {
    return null;
  }
  const isErased = ([x, y]) => (x - cx) ** 2 + (y - cy) ** 2 <= sqrReach;

  const points = stroke.points;
  const pb = points.length ? pointsBounds(points) : null;
  const isTiny =
    points.length < 2 ||
    Math.max(pb.right - pb.left, pb.bottom - pb.top) < stroke.options.s;
  if (stroke.shape || isTiny) {
    const ctx = hitContext();
    const touched =
      ctx.isPointInPath(pathOf(stroke), cx, cy) ||
      (stroke.polygon ?? []).some(isErased) ||
      points.some(isErased) ||
      (stroke.shape && touchesShapeOutline(stroke, cx, cy, reach));
    return touched ? [] : null;
  }

  const step = Math.max(radius / 3, 0.5);
  const dense = [points[0]];
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const p = points[i];
    const length = Math.hypot(p[0] - a[0], p[1] - a[1]);
    if (length > step && sqrDistanceToSegment(cx, cy, a[0], a[1], p[0], p[1]) <= sqrReach) {
      const count = Math.ceil(length / step);
      for (let j = 1; j < count; j++) {
        const t = j / count;
        const pressure =
          a[2] === undefined || p[2] === undefined ? (a[2] ?? p[2]) : a[2] + (p[2] - a[2]) * t;
        const point = [a[0] + (p[0] - a[0]) * t, a[1] + (p[1] - a[1]) * t];
        if (pressure !== undefined) point.push(pressure);
        dense.push(point);
      }
    }
    dense.push(p);
  }

  const pieces = [[]];
  let touched = false;
  for (const point of dense) {
    if (isErased(point)) {
      touched = true;
      if (pieces[pieces.length - 1].length) pieces.push([]);
    } else {
      pieces[pieces.length - 1].push(point);
    }
  }
  if (!touched) return null;
  return pieces
    .filter((piece) => piece.length >= 2)
    .map((piece) =>
      stroke.copy({
        id: newId(),
        points: piece.map((point) => [...point]),
        options: { ...stroke.options, f: true },
      }),
    );
}

function touchesShapeOutline(stroke, cx, cy, reach) {
  if (stroke.shape === 'circle') {
    return Math.abs(Math.hypot(cx - stroke.cx, cy - stroke.cy) - stroke.r) <= reach;
  }
  const { rl, rt, rw, rh } = stroke;
  const edges = [
    [rl, rt, rl + rw, rt],
    [rl + rw, rt, rl + rw, rt + rh],
    [rl, rt + rh, rl + rw, rt + rh],
    [rl, rt, rl, rt + rh],
  ];
  return edges.some(
    ([ax, ay, bx, by]) => sqrDistanceToSegment(cx, cy, ax, ay, bx, by) <= reach * reach,
  );
}

let hitCanvas;

function hitContext() {
  hitCanvas ??= document.createElement('canvas');
  hitCanvas.width = hitCanvas.height = 1;
  return hitCanvas.getContext('2d');
}

/** Returns the tape among `strokes` at (x, y), the topmost first. */
export function tapeAt(strokes, x, y) {
  const ctx = hitContext();
  for (let i = strokes.length - 1; i >= 0; i--) {
    const stroke = strokes[i];
    if (stroke.tool !== Tools.tape) continue;
    if (ctx.isPointInPath(pathOf(stroke), x, y)) return stroke;
  }
  return null;
}

/** The strokes that are mostly inside the lasso `polygon`. */
export function strokesInLasso(strokes, polygon) {
  const lasso = new Path2D();
  polygon.forEach(([x, y], i) => (i ? lasso.lineTo(x, y) : lasso.moveTo(x, y)));
  lasso.closePath();
  const ctx = hitContext();
  return strokes.filter((stroke) => {
    pathOf(stroke);
    const points = stroke.shape
      ? (() => {
          const b = boundsOf(stroke);
          return [
            [b.left, b.top],
            [b.right, b.top],
            [b.left, b.bottom],
            [b.right, b.bottom],
            [(b.left + b.right) / 2, (b.top + b.bottom) / 2],
          ];
        })()
      : stroke.polygon?.length
        ? stroke.polygon
        : stroke.points;
    if (!points.length) return false;
    let inside = 0;
    for (const [x, y] of points) if (ctx.isPointInPath(lasso, x, y)) inside++;
    return inside / points.length > 0.7;
  });
}

/** The box around `strokes`. */
export function boundsOfAll(strokes) {
  const result = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity };
  for (const stroke of strokes) {
    const b = boundsOf(stroke);
    result.left = Math.min(result.left, b.left);
    result.top = Math.min(result.top, b.top);
    result.right = Math.max(result.right, b.right);
    result.bottom = Math.max(result.bottom, b.bottom);
  }
  return result;
}

/** Whether `stroke` is a straight line, as the app checks for tape. */
export function isStraightLine(stroke) {
  const p = stroke.points;
  if (p.length < 3) return false;
  const [x0, y0] = p[0];
  const [x1, y1] = p[p.length - 1];
  const length = Math.hypot(x1 - x0, y1 - y0);
  if (length < 20) return false;
  let maxDistance = 0;
  for (const [x, y] of p) {
    maxDistance = Math.max(maxDistance, Math.sqrt(sqrDistanceToSegment(x, y, x0, y0, x1, y1)));
  }
  return maxDistance < length * 0.08;
}

export function straighten(stroke) {
  const p = stroke.points;
  const first = p[0];
  const last = p[p.length - 1];
  let [x0, y0] = first;
  let [x1, y1] = last;
  // snap to horizontal or vertical
  if (Math.abs(y1 - y0) < Math.abs(x1 - x0) * 0.1) y1 = y0;
  else if (Math.abs(x1 - x0) < Math.abs(y1 - y0) * 0.1) x1 = x0;
  stroke.points = [
    [x0, y0, first[2] ?? 0.5],
    [x1, y1, last[2] ?? 0.5],
    [x1, y1, last[2] ?? 0.5],
  ];
  stroke.invalidate();
}

export { Stroke };
