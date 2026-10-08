// A note as the app sees it, built from the operations that devices exchange
// through the server, and the operations that describe changes made here.
// This follows `lib/data/sync/realtime/note_ops.dart` in the app.

import { int } from './bson.js';
import { compose } from './delta.js';
import { base64Url, sha256 } from './sha256.js';

export const PAGE_WIDTH = 1000;
export const PAGE_HEIGHT = 1400;
export const FIRST_PAGE_ID = 'p0';

/** Pictures are sent in pieces of this many bytes, like in the app. */
const ASSET_CHUNK = 512 * 1024;

/** The tools, by the id that the app gives them. */
export const Tools = {
  fountainPen: 'fountainPen',
  ballpointPen: 'ballpointPen',
  pencil: 'Pencil',
  highlighter: 'Highlighter',
  shapePen: 'ShapePen',
  tape: 'tape',
};

/** The stroke options that the app leaves out when they have these values. */
export const DEFAULT_OPTIONS = {
  s: 10, // size
  t: 0.5, // thinning
  sm: 0, // smoothing
  sl: 0.5, // streamline
  sp: true, // simulate pressure
  cs: true, // cap the start
  ce: true, // cap the end
  f: true, // complete
};

const textEncoder = new TextEncoder();

/** A random id, like the app's `newId()`. */
export function newId() {
  return base64Url(crypto.getRandomValues(new Uint8Array(12)));
}

/** The id of the page that the app appends after the page `previousId`. */
export function derivePageId(previousId) {
  return 'p' + base64Url(sha256(textEncoder.encode(previousId)).subarray(0, 9));
}

let lastOpId = 0;

/** An id that grows with each operation from this device, like the app's. */
export function newOpId() {
  lastOpId = Math.max(Date.now() * 1000, lastOpId + 1);
  return lastOpId;
}

function decodePoints(binaries) {
  const points = [];
  for (const bytes of binaries) {
    const floats = new Float32Array(
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    );
    points.push(
      floats.length >= 3 ? [floats[0], floats[1], floats[2]] : [floats[0], floats[1]],
    );
  }
  return points;
}

function encodePoint(point) {
  const floats = new Float32Array(point.length >= 3 && point[2] != null ? 3 : 2);
  floats[0] = point[0];
  floats[1] = point[1];
  if (floats.length === 3) floats[2] = point[2];
  return new Uint8Array(floats.buffer);
}

export class Stroke {
  constructor(fields) {
    Object.assign(this, {
      id: newId(),
      tool: Tools.fountainPen,
      color: 0xff000000,
      pressureEnabled: true,
      options: { ...DEFAULT_OPTIONS },
      points: [],
      shape: null,
      revealed: false,
      ...fields,
    });
  }

  static fromJson(json) {
    const options = { ...DEFAULT_OPTIONS };
    for (const key of ['s', 't', 'sm', 'sl', 'sp', 'ts', 'te', 'cs', 'ce', 'f']) {
      if (json[key] !== undefined && json[key] !== null) options[key] = json[key];
    }
    const stroke = new Stroke({
      id: json.id || newId(),
      tool: json.ty ?? Tools.fountainPen,
      color: json.c ?? 0xff000000,
      pressureEnabled: json.pe ?? true,
      options,
      shape: json.shape ?? null,
    });
    if (stroke.shape === 'circle') {
      Object.assign(stroke, { cx: json.cx, cy: json.cy, r: json.r });
      stroke.tool = Tools.shapePen;
    } else if (stroke.shape === 'rect') {
      Object.assign(stroke, { rl: json.rl, rt: json.rt, rw: json.rw, rh: json.rh });
      stroke.tool = Tools.shapePen;
    } else {
      const ox = json.ox ?? 0;
      const oy = json.oy ?? 0;
      stroke.points = decodePoints(json.p ?? []).map(([x, y, p]) =>
        p === undefined ? [x + ox, y + oy] : [x + ox, y + oy, p],
      );
    }
    return stroke;
  }

  /** The stroke as the app saves and sends it, without its page index. */
  toJson() {
    const json = {
      shape: this.shape,
      id: this.id,
      pe: this.pressureEnabled,
      c: int(this.color >>> 0),
    };
    if (this.shape === 'circle') {
      Object.assign(json, { cx: this.cx, cy: this.cy, r: this.r });
    } else if (this.shape === 'rect') {
      Object.assign(json, { rl: this.rl, rt: this.rt, rw: this.rw, rh: this.rh });
    } else {
      json.p = this.points.map(encodePoint);
      json.ty = this.tool;
    }
    const o = this.options;
    if (o.s !== DEFAULT_OPTIONS.s) json.s = o.s;
    if (o.t !== DEFAULT_OPTIONS.t) json.t = o.t;
    if (o.sm !== DEFAULT_OPTIONS.sm) json.sm = o.sm;
    if (o.sl !== DEFAULT_OPTIONS.sl) json.sl = o.sl;
    if (o.ts !== undefined) json.ts = o.ts;
    if (o.te !== undefined) json.te = o.te;
    if (o.cs !== DEFAULT_OPTIONS.cs) json.cs = o.cs;
    if (o.ce !== DEFAULT_OPTIONS.ce) json.ce = o.ce;
    json.sp = o.sp;
    return json;
  }

  invalidate() {
    this.path = undefined;
    this.bounds = undefined;
  }

  shift(dx, dy) {
    if (!dx && !dy) return;
    if (this.shape === 'circle') {
      this.cx += dx;
      this.cy += dy;
    } else if (this.shape === 'rect') {
      this.rl += dx;
      this.rt += dy;
    } else {
      for (const point of this.points) {
        point[0] += dx;
        point[1] += dy;
      }
    }
    this.invalidate();
  }

  scale(ax, ay, factor) {
    if (factor === 1) return;
    if (this.shape === 'circle') {
      this.cx = ax + (this.cx - ax) * factor;
      this.cy = ay + (this.cy - ay) * factor;
      this.r *= factor;
    } else if (this.shape === 'rect') {
      this.rl = ax + (this.rl - ax) * factor;
      this.rt = ay + (this.rt - ay) * factor;
      this.rw *= factor;
      this.rh *= factor;
    } else {
      for (const point of this.points) {
        point[0] = ax + (point[0] - ax) * factor;
        point[1] = ay + (point[1] - ay) * factor;
      }
    }
    this.options = { ...this.options, s: this.options.s * factor };
    this.invalidate();
  }

  copy(fields = {}) {
    return new Stroke({
      ...this,
      options: { ...this.options },
      points: this.points.map((point) => [...point]),
      path: undefined,
      bounds: undefined,
      revealed: false,
      ...fields,
    });
  }
}

export class Page {
  constructor(id, width = PAGE_WIDTH, height = PAGE_HEIGHT) {
    this.id = id;
    this.width = width;
    this.height = height;
    this.strokes = [];
    this.images = [];
    this.backgroundImage = null;
    this.text = [{ insert: '\n' }];
    this.bookmark = null;
    this.study = null;
    this.version = 0; // changes whenever the page needs drawing again
  }

  get isEmpty() {
    return (
      this.strokes.length === 0 &&
      this.images.length === 0 &&
      !this.backgroundImage &&
      !this.text.some(
        (op) => typeof op.insert !== 'string' || op.insert.trim().length,
      )
    );
  }

  changed() {
    this.version++;
  }

  /** Adds `stroke` in its layer, like the app's `EditorPage.insertStroke`. */
  insertStroke(stroke) {
    let index = 0;
    for (const other of this.strokes) {
      if (other.tool > stroke.tool) break;
      if (
        other.tool === Tools.highlighter &&
        other.tool === stroke.tool &&
        (other.color >>> 0) > (stroke.color >>> 0)
      ) {
        break;
      }
      index++;
    }
    this.strokes.splice(index, 0, stroke);
    this.changed();
    return index;
  }
}

/** The files that images are drawn from, which arrive in pieces. */
class Assets {
  constructor() {
    this.complete = new Map();
    this.pieces = new Map();
  }

  addChunk(op) {
    const hash = op.h;
    if (this.complete.has(hash)) return;
    let chunks = this.pieces.get(hash);
    if (!chunks) {
      chunks = new Array(op.n).fill(null);
      this.pieces.set(hash, chunks);
    }
    if (op.i < 0 || op.i >= chunks.length) return;
    chunks[op.i] = op.b;
    if (chunks.includes(null)) return;
    const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    this.complete.set(hash, bytes);
    this.pieces.delete(hash);
  }
}

export class Note {
  constructor() {
    this.pages = [];
    this.backgroundPattern = '';
    this.flashcards = false;
    this.assets = new Assets();
    this.ensureBlankLastPage();
  }

  pageIndex(id) {
    return this.pages.findIndex((page) => page.id === id);
  }

  findStroke(id) {
    for (const page of this.pages) {
      const stroke = page.strokes.find((s) => s.id === id);
      if (stroke) return [page, stroke];
    }
    return [null, null];
  }

  findImage(uid) {
    for (const page of this.pages) {
      if (page.backgroundImage?.uid === uid) return [page, page.backgroundImage];
      const image = page.images.find((i) => i.uid === uid);
      if (image) return [page, image];
    }
    return [null, null];
  }

  /** Appends a blank page with the id that the app would give it. */
  appendPage() {
    let id = this.pages.length
      ? derivePageId(this.pages[this.pages.length - 1].id)
      : FIRST_PAGE_ID;
    while (this.pageIndex(id) >= 0) id = derivePageId(id);
    const page = new Page(id);
    this.pages.push(page);
    return page;
  }

  /** Keeps exactly one blank page at the end, like the app. */
  ensureBlankLastPage() {
    if (!this.pages.length || !this.pages[this.pages.length - 1].isEmpty) {
      this.appendPage();
    }
    while (
      this.pages.length >= 2 &&
      this.pages[this.pages.length - 1].isEmpty &&
      this.pages[this.pages.length - 2].isEmpty
    ) {
      this.pages.pop();
    }
  }

  /** Returns the page with id `pageId`, creating it if needed. */
  materializePage(pageId) {
    const existing = this.pageIndex(pageId);
    if (existing >= 0) return this.pages[existing];

    // most likely a page that another device appended to the end
    let derived = this.pages.length
      ? derivePageId(this.pages[this.pages.length - 1].id)
      : FIRST_PAGE_ID;
    for (let i = 0; i < 16; i++) {
      if (derived === pageId) {
        while (this.pageIndex(pageId) < 0) this.appendPage();
        return this.pages[this.pageIndex(pageId)];
      }
      derived = derivePageId(derived);
    }

    // otherwise the devices disagree on the id of the blank last page
    const last = this.pages[this.pages.length - 1];
    if (last?.isEmpty) {
      last.id = pageId;
      return last;
    }
    const page = new Page(pageId);
    this.pages.push(page);
    return page;
  }

  /** Applies an operation, from another device or from this one. */
  apply(op) {
    switch (op.t) {
      case 'as': {
        const json = op.s;
        if (this.findStroke(json.id)[1]) return;
        const page = this.materializePage(op.pg);
        page.insertStroke(Stroke.fromJson(json));
        break;
      }
      case 'rs':
        for (const id of op.ids) {
          const [page, stroke] = this.findStroke(id);
          if (!page) continue;
          page.strokes.splice(page.strokes.indexOf(stroke), 1);
          page.changed();
        }
        break;
      case 'ms':
        for (const id of op.ids) {
          const [page, stroke] = this.findStroke(id);
          stroke?.shift(op.dx, op.dy);
          page?.changed();
        }
        break;
      case 'ss':
        for (const id of op.ids) {
          const [page, stroke] = this.findStroke(id);
          stroke?.scale(op.x, op.y, op.f);
          page?.changed();
        }
        break;
      case 'cs':
        for (const [id, color] of Object.entries(op.c)) {
          const [page, stroke] = this.findStroke(id);
          if (!stroke) continue;
          stroke.color = color;
          stroke.invalidate();
          page.changed();
        }
        break;
      case 'ip': {
        if (this.pageIndex(op.id) >= 0) return;
        let index = 0;
        if (op.after != null) {
          const after = this.pageIndex(op.after);
          index = after < 0 ? this.pages.length : after + 1;
        }
        this.pages.splice(index, 0, new Page(op.id, op.w ?? PAGE_WIDTH, op.h ?? PAGE_HEIGHT));
        break;
      }
      case 'dp': {
        const index = this.pageIndex(op.id);
        if (index >= 0) this.pages.splice(index, 1);
        break;
      }
      case 'mp': {
        const from = this.pageIndex(op.id);
        if (from < 0) return;
        if (from === this.pages.length - 1 && this.pages[from].isEmpty) return;
        const [page] = this.pages.splice(from, 1);
        let to = 0;
        if (op.after != null) {
          const after = this.pageIndex(op.after);
          to = after < 0 ? this.pages.length : after + 1;
        }
        const last = this.pages.length - 1;
        if (to > last && last >= 0 && this.pages[last].isEmpty) to = last;
        this.pages.splice(to, 0, page);
        break;
      }
      case 'bg':
        this.backgroundPattern = op.p ?? '';
        for (const page of this.pages) page.changed();
        break;
      case 'ac':
        this.assets.addChunk(op);
        break;
      case 'ai': {
        const m = op.m;
        if (this.findImage(m.u)[1]) return;
        const bytes = this.assets.complete.get(op.h);
        if (!bytes) console.warn('Image added without its picture', m.u);
        const page = this.materializePage(op.pg);
        const image = {
          uid: m.u,
          extension: m.e ?? '.png',
          hash: op.h,
          length: op.n,
          bytes,
          x: m.x,
          y: m.y,
          w: m.w,
          h: m.h,
          sx: m.sx ?? 0,
          sy: m.sy ?? 0,
          sw: m.sw ?? 0,
          sh: m.sh ?? 0,
          invertible: m.v ?? true,
          fit: m.f ?? 1,
          nw: m.nw ?? 0,
          nh: m.nh ?? 0,
        };
        if (op.bg) page.backgroundImage = image;
        else page.images.push(image);
        page.changed();
        break;
      }
      case 'ri':
        for (const uid of op.ids) {
          const [page, image] = this.findImage(uid);
          if (!page) continue;
          if (page.backgroundImage === image) page.backgroundImage = null;
          else page.images.splice(page.images.indexOf(image), 1);
          page.changed();
        }
        break;
      case 'ui': {
        const [page, image] = this.findImage(op.id);
        if (!image) return;
        Object.assign(image, { x: op.x, y: op.y, w: op.w, h: op.h });
        if (op.sw) Object.assign(image, { sx: op.sx, sy: op.sy, sw: op.sw, sh: op.sh });
        if (op.bg && page.backgroundImage !== image) {
          if (page.backgroundImage) page.images.push(page.backgroundImage);
          page.images.splice(page.images.indexOf(image), 1);
          page.backgroundImage = image;
        } else if (!op.bg && page.backgroundImage === image) {
          page.backgroundImage = null;
          page.images.push(image);
        }
        page.changed();
        break;
      }
      case 'qt': {
        const page = this.materializePage(op.pg);
        page.text = op.q;
        page.changed();
        break;
      }
      case 'qd': {
        if (!op.d?.length) return;
        const page = this.materializePage(op.pg);
        page.text = compose(page.text, op.d);
        page.changed();
        break;
      }
      case 'fl':
        this.flashcards = op.on === true;
        break;
      case 'fc': {
        const index = this.pageIndex(op.pg);
        if (index >= 0) this.pages[index].study = op.c ?? null;
        break;
      }
      case 'bm': {
        const index = this.pageIndex(op.pg);
        if (index >= 0) {
          this.pages[index].bookmark = op.b ?? null;
          this.pages[index].changed();
        }
        break;
      }
      default:
        console.warn('Unknown operation', op.t);
        return;
    }
    this.ensureBlankLastPage();
  }
}

/** The operations that describe changes made on this device. */
export const Ops = {
  addStroke: (page, stroke) => ({ t: 'as', pg: page.id, s: stroke.toJson() }),
  removeStrokes: (strokes) => ({ t: 'rs', ids: strokes.map((s) => s.id) }),
  moveStrokes: (strokes, dx, dy) => ({
    t: 'ms',
    ids: strokes.map((s) => s.id),
    dx,
    dy,
  }),
  scaleStrokes: (strokes, x, y, f) => ({
    t: 'ss',
    ids: strokes.map((s) => s.id),
    x,
    y,
    f,
  }),
  colorStrokes: (colors) => ({
    t: 'cs',
    c: Object.fromEntries(colors.map(([stroke, color]) => [stroke.id, int(color >>> 0)])),
  }),
  insertPage: (page, afterId) => ({
    t: 'ip',
    id: page.id,
    after: afterId ?? null,
    w: page.width,
    h: page.height,
  }),
  deletePage: (page) => ({ t: 'dp', id: page.id }),
  movePage: (page, afterId) => ({ t: 'mp', id: page.id, after: afterId ?? null }),
  backgroundPattern: (pattern) => ({ t: 'bg', p: pattern }),
  bookmark: (page) => ({ t: 'bm', pg: page.id, b: page.bookmark }),
  flashcards: (on) => ({ t: 'fl', on }),
  study: (page) => ({ t: 'fc', pg: page.id, c: page.study }),

  /** The operations that add `image` to `page`, with its picture. */
  addImage(page, image, { sendAsset = true } = {}) {
    const ops = [];
    if (sendAsset) {
      const count = Math.max(1, Math.ceil(image.bytes.length / ASSET_CHUNK));
      for (let i = 0; i < count; i++) {
        ops.push({
          t: 'ac',
          h: image.hash,
          i: int(i),
          n: int(count),
          b: image.bytes.subarray(i * ASSET_CHUNK, Math.min(image.bytes.length, (i + 1) * ASSET_CHUNK)),
        });
      }
    }
    ops.push({
      t: 'ai',
      pg: page.id,
      bg: page.backgroundImage === image,
      h: image.hash,
      n: int(image.bytes.length),
      m: {
        u: image.uid,
        e: image.extension,
        v: image.invertible,
        f: int(image.fit ?? 1),
        x: image.x,
        y: image.y,
        w: image.w,
        h: image.h,
        ...(image.nw ? { nw: image.nw, nh: image.nh } : {}),
      },
    });
    return ops;
  },
  removeImages: (images) => ({ t: 'ri', ids: images.map((image) => image.uid) }),
  /** Where and how `image` is shown, `rect` being its position then. */
  updateImage: (page, image, rect = image) => ({
    t: 'ui',
    id: image.uid,
    bg: page.backgroundImage === image,
    x: rect.x,
    y: rect.y,
    w: rect.w,
    h: rect.h,
    sx: image.sx ?? 0,
    sy: image.sy ?? 0,
    sw: image.sw ?? 0,
    sh: image.sh ?? 0,
    v: image.invertible ?? true,
    f: int(image.fit ?? 1),
  }),
};
