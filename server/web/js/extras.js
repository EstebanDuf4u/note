// Elements (handwriting saved to add again), the text of a page, and
// exporting a note as a pdf.

import { compose, lines } from './delta.js';
import { Stroke, newId } from './model.js';
import { boundsOf, drawPage } from './render.js';

// Elements

const ELEMENTS_KEY = 'noteplus.elements';
const MAX_ELEMENTS = 60;

export const Elements = {
  all() {
    try {
      return JSON.parse(localStorage.getItem(ELEMENTS_KEY) ?? '[]');
    } catch {
      return [];
    }
  },

  save(elements) {
    try {
      localStorage.setItem(ELEMENTS_KEY, JSON.stringify(elements.slice(0, MAX_ELEMENTS)));
    } catch {
      // storage is full or unavailable
    }
  },

  /** Saves `strokes` as an element, with its top left corner at 0,0. */
  add(strokes) {
    if (!strokes.length) return null;
    let left = Infinity;
    let top = Infinity;
    let right = -Infinity;
    let bottom = -Infinity;
    for (const stroke of strokes) {
      const b = boundsOf(stroke);
      left = Math.min(left, b.left);
      top = Math.min(top, b.top);
      right = Math.max(right, b.right);
      bottom = Math.max(bottom, b.bottom);
    }
    const element = {
      id: newId(),
      w: right - left,
      h: bottom - top,
      strokes: strokes.map((stroke) => {
        const copy = stroke.copy();
        copy.shift(-left, -top);
        return {
          tool: copy.tool,
          color: copy.color,
          pressureEnabled: copy.pressureEnabled,
          options: copy.options,
          points: copy.points,
          shape: copy.shape,
          ...(copy.shape === 'circle' ? { cx: copy.cx, cy: copy.cy, r: copy.r } : {}),
          ...(copy.shape === 'rect' ? { rl: copy.rl, rt: copy.rt, rw: copy.rw, rh: copy.rh } : {}),
        };
      }),
    };
    this.save([element, ...this.all()]);
    return element;
  },

  remove(id) {
    this.save(this.all().filter((element) => element.id !== id));
  },

  /** New strokes like those of `element`, with its corner at (x, y). */
  strokesOf(element, x = 0, y = 0) {
    return element.strokes.map((fields) => {
      const stroke = new Stroke({
        ...fields,
        id: newId(),
        options: { ...fields.options },
        points: fields.points.map((point) => [...point]),
      });
      stroke.shift(x, y);
      return stroke;
    });
  },
};

// Text

/** The text of a page as plain text, objects (like images) as a placeholder. */
export function plainText(document) {
  return document.map((op) => (typeof op.insert === 'string' ? op.insert : '￼')).join('');
}

/**
 * The change from the text `before` to the text `after`,
 * as the smallest replacement in the middle.
 */
export function textChange(before, after) {
  let start = 0;
  while (start < before.length && start < after.length && before[start] === after[start]) start++;
  let end = 0;
  while (
    end < before.length - start &&
    end < after.length - start &&
    before[before.length - 1 - end] === after[after.length - 1 - end]
  ) {
    end++;
  }
  const change = [];
  if (start) change.push({ retain: start });
  const removed = before.length - start - end;
  if (removed) change.push({ delete: removed });
  const inserted = after.slice(start, after.length - end);
  if (inserted) change.push({ insert: inserted });
  return change.length && !(change.length === 1 && change[0].retain) ? change : [];
}

export { compose, lines };

// PDF

/**
 * A pdf with one page per picture, each a jpeg of `width` x `height` pixels,
 * on pages of `pageWidth` x `pageHeight` points.
 */
export function makePdf(pictures, { pageWidth, pageHeight }) {
  const encoder = new TextEncoder();
  const parts = [];
  const offsets = [];
  let length = 0;
  const add = (part) => {
    const bytes = typeof part === 'string' ? encoder.encode(part) : part;
    parts.push(bytes);
    length += bytes.length;
  };
  const object = (id, body, stream) => {
    offsets[id] = length;
    add(`${id} 0 obj\n${body}\n`);
    if (stream) {
      add('stream\n');
      add(stream);
      add('\nendstream\n');
    }
    add('endobj\n');
  };

  add('%PDF-1.4\n%âãÏÓ\n');
  const pageIds = pictures.map((_, i) => 3 + i * 3);
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pictures.length} >>`);
  pictures.forEach((picture, i) => {
    const pageId = pageIds[i];
    const contentId = pageId + 1;
    const imageId = pageId + 2;
    object(
      pageId,
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth} ${pageHeight}] ` +
        `/Resources << /XObject << /Im${i} ${imageId} 0 R >> >> /Contents ${contentId} 0 R >>`,
    );
    const content = encoder.encode(`q ${pageWidth} 0 0 ${pageHeight} 0 0 cm /Im${i} Do Q`);
    object(contentId, `<< /Length ${content.length} >>`, content);
    object(
      imageId,
      `<< /Type /XObject /Subtype /Image /Width ${picture.width} /Height ${picture.height} ` +
        `/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${picture.bytes.length} >>`,
      picture.bytes,
    );
  });
  const count = 3 + pictures.length * 3;
  const xref = length;
  let table = `xref\n0 ${count}\n0000000000 65535 f \n`;
  for (let id = 1; id < count; id++) table += `${String(offsets[id]).padStart(10, '0')} 00000 n \n`;
  add(table);
  add(`trailer\n<< /Size ${count} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);

  const pdf = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    pdf.set(part, offset);
    offset += part.length;
  }
  return pdf;
}

/** The pages of `note` that have something on them, as a pdf. */
export async function exportPdf(note) {
  const pages = note.pages.filter((page) => !page.isEmpty);
  if (!pages.length) return null;
  const scale = 1.6;
  const pictures = [];
  for (const page of pages) {
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(page.width * scale);
    canvas.height = Math.round(page.height * scale);
    const ctx = canvas.getContext('2d');
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    drawPage(ctx, note, page, {});
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.9));
    pictures.push({ bytes: new Uint8Array(await blob.arrayBuffer()), width: canvas.width, height: canvas.height });
  }
  // a page of the app is 1000 x 1400, about the proportions of A4
  return makePdf(pictures, { pageWidth: 595, pageHeight: 833 });
}
