// Draws pages like the app does: `_canvas_background_painter.dart`,
// `_canvas_painter.dart` and the text of `inner_canvas.dart`.

import { getStroke } from './vendor/perfect-freehand.mjs';
import { lines } from './delta.js';
import { Tools } from './model.js';

export const LINE_HEIGHT = 40;
const LINE_THICKNESS = 3;
const HIGHLIGHTER_ALPHA = 100 / 255;
export const PATTERN_COLOR = 'rgba(79, 70, 229, 0.2)';
export const MARGIN_COLOR = 'rgba(225, 29, 72, 0.2)';

/** A css color for an ARGB `color`, optionally with another alpha. */
export function cssColor(color, alpha) {
  color >>>= 0;
  const a = alpha ?? ((color >>> 24) & 0xff) / 255;
  return `rgba(${(color >>> 16) & 0xff}, ${(color >>> 8) & 0xff}, ${color & 0xff}, ${a})`;
}

function taperOf(value) {
  if (value === undefined || value === null) return 0;
  return value < 0 ? true : value;
}

/** The outline of a freehand stroke, as a closed polygon. */
export function strokePolygon(stroke, { last = stroke.options.f } = {}) {
  const o = stroke.options;
  const points = stroke.pressureEnabled
    ? stroke.points
    : stroke.points.map(([x, y]) => [x, y]);
  return getStroke(points, {
    size: o.s,
    thinning: o.t,
    smoothing: o.sm,
    streamline: o.sl,
    simulatePressure: stroke.pressureEnabled ? o.sp : false,
    last,
    start: { cap: o.cs, taper: taperOf(o.ts) },
    end: { cap: o.ce, taper: taperOf(o.te) },
  });
}

/** Like the app's `Stroke.smoothPathFromPolygon`. */
export function smoothPath(polygon) {
  const path = new Path2D();
  if (polygon.length < 3) return path;
  path.moveTo(polygon[0][0], polygon[0][1]);
  for (let i = 1; i < polygon.length - 1; i++) {
    const [x1, y1] = polygon[i];
    const [x2, y2] = polygon[i + 1];
    path.quadraticCurveTo(x1, y1, (x1 + x2) / 2, (y1 + y2) / 2);
  }
  path.closePath();
  return path;
}

/** The path that fills `stroke`, which is kept until the stroke changes. */
export function pathOf(stroke) {
  if (stroke.path) return stroke.path;
  if (stroke.shape === 'circle') {
    const path = new Path2D();
    path.arc(stroke.cx, stroke.cy, stroke.r, 0, Math.PI * 2);
    stroke.path = path;
  } else if (stroke.shape === 'rect') {
    const path = new Path2D();
    path.rect(stroke.rl, stroke.rt, stroke.rw, stroke.rh);
    stroke.path = path;
  } else {
    stroke.polygon = strokePolygon(stroke);
    stroke.path = smoothPath(stroke.polygon);
  }
  return stroke.path;
}

/** The box around `stroke`, in page coordinates. */
export function boundsOf(stroke) {
  if (stroke.bounds) return stroke.bounds;
  let bounds;
  if (stroke.shape === 'circle') {
    const r = stroke.r + stroke.options.s / 2;
    bounds = { left: stroke.cx - r, top: stroke.cy - r, right: stroke.cx + r, bottom: stroke.cy + r };
  } else if (stroke.shape === 'rect') {
    const half = stroke.options.s / 2;
    bounds = {
      left: stroke.rl - half,
      top: stroke.rt - half,
      right: stroke.rl + stroke.rw + half,
      bottom: stroke.rt + stroke.rh + half,
    };
  } else {
    pathOf(stroke);
    bounds = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity };
    for (const [x, y] of stroke.polygon.length ? stroke.polygon : stroke.points) {
      bounds.left = Math.min(bounds.left, x);
      bounds.top = Math.min(bounds.top, y);
      bounds.right = Math.max(bounds.right, x);
      bounds.bottom = Math.max(bounds.bottom, y);
    }
  }
  stroke.bounds = bounds;
  return bounds;
}

function drawShape(ctx, stroke, color) {
  ctx.strokeStyle = color;
  ctx.lineWidth = stroke.options.s;
  ctx.lineJoin = 'round';
  ctx.stroke(pathOf(stroke));
}

export function drawStroke(ctx, stroke, { selected = false } = {}) {
  let color = cssColor(stroke.color, stroke.tool === Tools.pencil ? 0.82 : 1);
  if (selected) color = 'rgba(79, 70, 229, 0.85)';
  if (stroke.tool === Tools.tape) return drawTape(ctx, stroke);
  if (stroke.shape) return drawShape(ctx, stroke, color);
  ctx.fillStyle = color;
  ctx.fill(pathOf(stroke));
}

/** Tape hides what's under it until it's tapped. */
export function drawTape(ctx, tape) {
  const path = pathOf(tape);
  const color = cssColor(tape.color, 1);
  if (tape.revealed) {
    ctx.fillStyle = cssColor(tape.color, 0.12);
    ctx.fill(path);
    ctx.save();
    ctx.setLineDash([6, 4]);
    ctx.strokeStyle = cssColor(tape.color, 0.7);
    ctx.lineWidth = 1.5;
    ctx.stroke(path);
    ctx.restore();
    return;
  }
  ctx.fillStyle = color;
  ctx.fill(path);
  const b = boundsOf(tape);
  ctx.save();
  ctx.clip(path);
  ctx.strokeStyle = 'rgba(255, 255, 255, 0.18)';
  ctx.lineWidth = 4;
  const height = b.bottom - b.top;
  ctx.beginPath();
  for (let x = b.left - height; x < b.right; x += 12) {
    ctx.moveTo(x, b.bottom);
    ctx.lineTo(x + height, b.top);
  }
  ctx.stroke();
  ctx.restore();
}

function patternLines(pattern, width, height) {
  const h = LINE_HEIGHT;
  const result = [];
  const line = (x1, y1, x2, y2, secondary = false) =>
    result.push({ x1, y1, x2, y2, secondary });
  switch (pattern) {
    case 'college':
    case 'college-rtl':
    case 'lined':
      for (let y = h * 2; y < height; y += h) line(0, y, width, y);
      if (pattern === 'college') line(h * 2, 0, h * 2, height, true);
      if (pattern === 'college-rtl') line(width - h * 2, 0, width - h * 2, height, true);
      break;
    case 'grid':
      for (let y = h * 2; y < height; y += h) line(0, y, width, y);
      for (let x = 0; x < width; x += h) line(x, h * 2, x, height);
      break;
    case 'staffs':
    case 'tablature': {
      const spaces = pattern === 'staffs' ? 4 : 5;
      const staffHeight = h * spaces;
      const spacing = h * 3;
      for (let top = spacing - h; top + staffHeight < height; top += staffHeight + spacing) {
        for (let i = 0; i <= spaces; i++) line(h, top + h * i, width - h, top + h * i);
        line(h, top, h, top + staffHeight);
        line(width - h, top, width - h, top + staffHeight);
      }
      break;
    }
    case 'cornell': {
      line(h, h * 2, width / 2 - h / 2, h * 2);
      line(width / 2 + h / 2, h * 2, width - h, h * 2);
      line(h, h * 3, width - h, h * 3);
      const left = width * 0.35;
      const bottom = height * 0.7;
      for (let y = h * 5; y < bottom; y += h) line(left, y, width - h, y);
      break;
    }
  }
  return result;
}

export function drawBackground(ctx, note, page) {
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, page.width, page.height);
  if (page.backgroundImage) return;
  const pattern = note.backgroundPattern;
  if (pattern === 'dots') {
    ctx.fillStyle = PATTERN_COLOR;
    for (let y = LINE_HEIGHT * 2; y <= page.height; y += LINE_HEIGHT) {
      for (let x = 0; x <= page.width; x += LINE_HEIGHT) {
        ctx.beginPath();
        ctx.arc(x, y, (LINE_THICKNESS * 4) / 3, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    return;
  }
  ctx.lineWidth = LINE_THICKNESS;
  for (const l of patternLines(pattern, page.width, page.height)) {
    ctx.strokeStyle = l.secondary ? MARGIN_COLOR : PATTERN_COLOR;
    ctx.beginPath();
    ctx.moveTo(l.x1, l.y1);
    ctx.lineTo(l.x2, l.y2);
    ctx.stroke();
  }
}

const imageElements = new WeakMap();

const MIME_TYPES = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
};

/** The loaded picture of `image`, or null while it loads. */
function elementOf(image, note, onLoad) {
  if (!image.bytes) image.bytes = note.assets.complete.get(image.hash);
  if (!image.bytes) return null;
  let element = imageElements.get(image);
  if (!element) {
    const type = MIME_TYPES[image.extension?.toLowerCase()];
    if (!type) return null; // e.g. pdf pages, drawn as a placeholder
    element = new Image();
    element.onload = onLoad;
    element.src = URL.createObjectURL(new Blob([image.bytes], { type }));
    imageElements.set(image, element);
  }
  return element.complete && element.naturalWidth ? element : null;
}

function drawImage(ctx, note, page, image, onLoad, background) {
  const element = elementOf(image, note, onLoad);
  let { x, y, w, h } = image;
  if (background) {
    x = 0;
    y = 0;
    w = page.width;
    h = page.height;
  }
  if (!element) {
    ctx.fillStyle = '#f1f1f4';
    ctx.fillRect(x, y, w, h);
    ctx.strokeStyle = '#d4d4dc';
    ctx.lineWidth = 2;
    ctx.strokeRect(x, y, w, h);
    if (image.extension === '.pdf' && w > 80) {
      ctx.fillStyle = '#9a9aa8';
      ctx.font = '600 28px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('PDF', x + w / 2, y + h / 2);
      ctx.textAlign = 'start';
    }
    return;
  }
  if (image.sw && image.sh) {
    ctx.drawImage(element, image.sx, image.sy, image.sw, image.sh, x, y, w, h);
  } else if (background) {
    // contain, like the app's default fit
    const scale = Math.min(w / element.naturalWidth, h / element.naturalHeight);
    const dw = element.naturalWidth * scale;
    const dh = element.naturalHeight * scale;
    ctx.drawImage(element, (w - dw) / 2, (h - dh) / 2, dw, dh);
  } else {
    ctx.drawImage(element, x, y, w, h);
  }
}

const HEADER_SIZES = { 1: 1.15, 2: 1, 3: 0.9 };

function drawText(ctx, page) {
  const text = lines(page.text);
  if (!text.length) return;
  ctx.fillStyle = '#000000';
  ctx.textBaseline = 'alphabetic';
  let y = LINE_HEIGHT * 1.2;
  for (const line of text) {
    const header = line.attributes.header;
    let x = LINE_HEIGHT * 0.5;
    if (line.attributes.list) {
      ctx.font = `${LINE_HEIGHT}px Neucha, cursive`;
      ctx.fillText(line.attributes.list === 'ordered' ? '1.' : '•', x, y + LINE_HEIGHT * 0.8);
      x += LINE_HEIGHT;
    }
    for (const span of line.spans) {
      const a = span.attributes;
      const size = LINE_HEIGHT * (a.size === 'small' ? 0.7 : (HEADER_SIZES[header] ?? 1));
      ctx.font = `${a.italic ? 'italic ' : ''}${a.bold || header ? 'bold ' : ''}${size}px Neucha, cursive`;
      ctx.fillStyle = a.color ?? '#000000';
      ctx.fillText(span.text, x, y + LINE_HEIGHT * 0.8);
      const width = ctx.measureText(span.text).width;
      if (a.underline || a.strike) {
        ctx.fillRect(x, y + LINE_HEIGHT * (a.strike ? 0.55 : 0.88), width, 2);
      }
      x += width;
    }
    y += LINE_HEIGHT;
  }
}

/**
 * Draws `page` into `ctx`, which is scaled to page coordinates.
 * `hidden` strokes aren't drawn, e.g. while they're being moved.
 */
export function drawPage(ctx, note, page, { onImageLoad, selected, hidden } = {}) {
  drawBackground(ctx, note, page);
  if (note.flashcards) drawCardDivider(ctx, page);
  if (page.backgroundImage) {
    drawImage(ctx, note, page, page.backgroundImage, onImageLoad, true);
  }
  for (const image of page.images) drawImage(ctx, note, page, image, onImageLoad, false);
  drawText(ctx, page);

  // Highlighters are drawn in a layer that darkens what's below it,
  // so overlaps don't get darker, like in the app.
  const highlighters = page.strokes.filter(
    (s) => s.tool === Tools.highlighter && !hidden?.has(s),
  );
  if (highlighters.length) {
    const layer = highlighterLayer(ctx);
    const lctx = layer.getContext('2d');
    lctx.setTransform(1, 0, 0, 1, 0, 0);
    lctx.clearRect(0, 0, layer.width, layer.height);
    lctx.setTransform(ctx.getTransform());
    for (const stroke of highlighters) {
      lctx.fillStyle = cssColor(stroke.color, 1);
      lctx.fill(pathOf(stroke));
    }
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalAlpha = HIGHLIGHTER_ALPHA;
    ctx.globalCompositeOperation = 'multiply';
    ctx.drawImage(layer, 0, 0);
    ctx.restore();
  }

  for (const stroke of page.strokes) {
    if (stroke.tool === Tools.highlighter || hidden?.has(stroke)) continue;
    drawStroke(ctx, stroke, { selected: selected?.has(stroke) });
  }
}

/** In flashcards mode, a dashed line splits the question from the answer. */
function drawCardDivider(ctx, page) {
  ctx.save();
  ctx.strokeStyle = 'rgba(79, 70, 229, 0.45)';
  ctx.lineWidth = 2;
  ctx.setLineDash([14, 10]);
  ctx.beginPath();
  ctx.moveTo(0, page.height / 2);
  ctx.lineTo(page.width, page.height / 2);
  ctx.stroke();
  ctx.restore();
}

let layerCanvas;

function highlighterLayer(ctx) {
  const { width, height } = ctx.canvas;
  if (!layerCanvas) layerCanvas = document.createElement('canvas');
  if (layerCanvas.width !== width || layerCanvas.height !== height) {
    layerCanvas.width = width;
    layerCanvas.height = height;
  }
  return layerCanvas;
}
