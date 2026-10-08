// The editor: a note's pages, drawn on a canvas, with the tools to write.

import { Api } from './api.js';
import { deserialize, serialize } from './bson.js';
import {
  boundsOfAll,
  erasedAround,
  isStraightLine,
  straighten,
  strokesInLasso,
  tapeAt,
} from './geometry.js';
import { copyShareLink, errorMessage, PAPERS } from './library.js';
import { Note, Ops, Page, Stroke, Tools, newId } from './model.js';
import { boundsOf, cssColor, drawPage, drawStroke, smoothPath, strokePolygon } from './render.js';
import { Session } from './session.js';
import { colorOf, confirm, h, icon, initials, prompt, sheet, toast } from './ui.js';

const GAP = 36; // between pages, in page units
const MAX_CACHE_PIXELS = 2_800_000; // per page, to stay within iOS's canvas memory
const HANDLE_RADIUS = 22; // in screen pixels

const COLORS = [
  0xff000000, 0xff3c3c46, 0xff1e40af, 0xff2563eb, 0xff0e7490, 0xff15803d,
  0xffb91c1c, 0xffea580c, 0xffca8a04, 0xff7e22ce, 0xffdb2777, 0xff78350f,
];
const HIGHLIGHTER_COLORS = [
  0xffffeb3b, 0xff9ae66e, 0xff7dd3fc, 0xfff9a8d4, 0xfffdba74, 0xffc4b5fd,
  0xffa7f3d0, 0xfffca5a5,
];
const TAPE_COLORS = [0xfff2b84b, 0xff7dd3fc, 0xfff9a8d4, 0xffa7f3d0, 0xffc4b5fd, 0xffd6d3d1];

/** The pens, with the settings that make them look like the app's. */
const PENS = {
  fountainPen: {
    tool: Tools.fountainPen,
    icon: 'fountain',
    name: 'Stylo plume',
    sizes: [3, 5, 9],
    colors: COLORS,
    pressure: true,
    options: { t: 0.5, sm: 0, sl: 0.5 },
  },
  ballpointPen: {
    tool: Tools.ballpointPen,
    icon: 'ballpoint',
    name: 'Stylo bille',
    sizes: [2.5, 4, 7],
    colors: COLORS,
    pressure: false,
    options: { t: 0.5, sm: 0, sl: 0.5 },
  },
  pencil: {
    tool: Tools.pencil,
    icon: 'pencil',
    name: 'Crayon',
    sizes: [3, 5, 8],
    colors: COLORS,
    pressure: true,
    options: { t: 0.5, sm: 0, sl: 0.1, ts: 1, te: 1 },
  },
  highlighter: {
    tool: Tools.highlighter,
    icon: 'highlighter',
    name: 'Surligneur',
    sizes: [25, 40, 60],
    colors: HIGHLIGHTER_COLORS,
    pressure: false,
    alpha: 100,
    options: { t: 0.5, sm: 0, sl: 0.5 },
  },
  tape: {
    tool: Tools.tape,
    icon: 'tape',
    name: 'Ruban adhésif',
    sizes: [20, 30, 44],
    colors: TAPE_COLORS,
    pressure: false,
    options: { t: 0, sm: 0.7, sl: 0.7 },
  },
};

const ERASER_SIZES = [6, 12, 24];

function load(key, fallback) {
  try {
    const value = localStorage.getItem('noteplus.' + key);
    return value === null ? fallback : JSON.parse(value);
  } catch {
    return fallback;
  }
}

function save(key, value) {
  try {
    localStorage.setItem('noteplus.' + key, JSON.stringify(value));
  } catch {
    // private browsing
  }
}

function base64(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function unbase64(text) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

export class Editor {
  /**
   * @param {HTMLElement} root
   * @param {object} options
   * @param {string} options.path where the note is in its owner's library
   * @param {string} options.name the note's name
   * @param {string} [options.share] the token of its link, if it's another
   *   account's note
   * @param {boolean} [options.create] whether it's a new note
   * @param {string} [options.paper] the background of a new note
   * @param {() => void} options.onClose
   */
  constructor(root, options) {
    this.root = root;
    this.options = options;
    this.note = new Note();
    this.camera = { x: 0, y: 0, z: 1 };
    this.dpr = Math.min(window.devicePixelRatio || 1, 3);
    this.caches = new Map();
    this.undoStack = [];
    this.redoStack = [];
    this.pointers = new Map();
    this.presences = new Map();
    this.loaded = false;

    this.tool = load('tool', 'fountainPen');
    this.penSettings = load('pens', {});
    this.eraser = load('eraser', { partial: true, size: 12 });
    this.penSeen = load('penSeen', false);
    this.fingerDraws = load('fingerDraws', true);

    this.build();
    this.connect();
    this.resize();
    this.fitWidth();
    this.requestFrame();
  }

  // Interface

  build() {
    this.canvas = h('canvas.view');
    this.ctx = this.canvas.getContext('2d');

    this.status = h('div.status', {}, 'Connexion…');
    this.presenceEl = h('div.presence');
    this.undoButton = h(
      'button.icon-btn',
      { onclick: () => this.undo(), 'aria-label': 'Annuler', disabled: true },
      icon('undo'),
    );
    this.redoButton = h(
      'button.icon-btn',
      { onclick: () => this.redo(), 'aria-label': 'Rétablir', disabled: true },
      icon('redo'),
    );
    const header = h(
      'header.editor-header',
      {},
      h('button.back', { onclick: () => this.close() }, icon('back'), h('span', {}, 'Carnets')),
      h('div.title', {}, h('strong', {}, this.options.name), this.status),
      h(
        'div.actions',
        {},
        this.presenceEl,
        this.undoButton,
        this.redoButton,
        h(
          'button.icon-btn.hide-narrow',
          { onclick: () => this.showPages(), 'aria-label': 'Pages' },
          icon('pages'),
        ),
        h('button.icon-btn', { onclick: () => this.showMenu(), 'aria-label': 'Plus' }, icon('more')),
      ),
    );

    this.dock = h('div.dock');
    this.pagePill = h('button.page-pill', { onclick: () => this.showPages() }, '');
    this.overlayLayer = h('div');
    this.loading = h('div.offline-banner', {}, h('div.spinner'), 'Ouverture du carnet…');

    this.element = h(
      'div.editor',
      {},
      this.canvas,
      header,
      this.loading,
      this.pagePill,
      this.dock,
      this.overlayLayer,
    );
    this.root.replaceChildren(this.element);
    this.renderDock();
    const readDesk = () => {
      this.deskColor = getComputedStyle(this.element).getPropertyValue('--desk').trim() || '#e9e9ef';
      this.requestFrame();
    };
    readDesk();
    this.darkMode = matchMedia('(prefers-color-scheme: dark)');
    this.darkMode.addEventListener?.('change', readDesk);

    this.canvas.addEventListener('pointerdown', (e) => this.onPointerDown(e));
    this.canvas.addEventListener('pointermove', (e) => this.onPointerMove(e));
    this.canvas.addEventListener('pointerup', (e) => this.onPointerUp(e));
    this.canvas.addEventListener('pointercancel', (e) => this.onPointerUp(e, true));
    this.canvas.addEventListener('wheel', (e) => this.onWheel(e), { passive: false });
    // Safari's own pinch zoom
    this.onGesture = (e) => e.preventDefault();
    document.addEventListener('gesturestart', this.onGesture);
    document.addEventListener('gesturechange', this.onGesture);

    this.onResize = () => {
      this.resize();
      this.clampCamera();
      this.requestFrame();
    };
    window.addEventListener('resize', this.onResize);
    this.onKey = (e) => this.onKeyDown(e);
    document.addEventListener('keydown', this.onKey);
    this.onBeforeUnload = (e) => {
      if (this.session?.hasPending) {
        e.preventDefault();
        e.returnValue = '';
      }
    };
    window.addEventListener('beforeunload', this.onBeforeUnload);
    document.fonts?.ready.then(() => {
      this.invalidateAll();
      this.requestFrame();
    });
  }

  renderDock() {
    // the fountain pen and the ballpoint share a button, to fit on phones
    const penTool = this.tool === 'ballpointPen' || this.tool === 'fountainPen'
      ? this.tool
      : load('lastPen', 'fountainPen');
    const tools = [
      [penTool, PENS[penTool].icon, PENS[penTool].name],
      ['pencil', PENS.pencil.icon, 'Crayon'],
      ['highlighter', PENS.highlighter.icon, 'Surligneur'],
      ['eraser', 'eraser', 'Gomme'],
      ['lasso', 'lasso', 'Lasso'],
      ['tape', 'tape', 'Ruban adhésif'],
    ];
    const pen = PENS[this.tool];
    const settings = pen ? this.settingsOf(this.tool) : null;
    this.dock.replaceChildren(
      ...[
      ...tools.map(([tool, iconName, label]) => {
        const selected = this.tool === tool;
        const tipColor = PENS[tool] ? cssColor(this.settingsOf(tool).color, 1) : 'var(--brand)';
        return h(
          'button.tool' + (selected ? '.selected' : ''),
          {
            'aria-label': label,
            title: label,
            onclick: () => {
              if (this.tool === tool && (PENS[tool] || tool === 'eraser')) {
                this.togglePopover();
              } else {
                this.setTool(tool);
              }
            },
          },
          icon(iconName),
          h('span.tip', { style: { background: tipColor } }),
        );
      }),
      h('div.sep'),
      pen
        ? h(
            'button.tool',
            { onclick: () => this.togglePopover(), 'aria-label': 'Couleur et taille' },
            h('div.color-dot', { style: { background: cssColor(settings.color, 1) } }),
          )
        : null,
      matchMedia('(pointer: coarse)').matches || this.penSeen
        ? h(
            'button.tool' + (this.fingerDraws && !this.penSeen ? '' : '.selected'),
            {
              'aria-label': 'Le doigt fait défiler',
              title: this.penSeen
                ? 'Avec le stylet, le doigt fait défiler'
                : 'Le doigt fait défiler au lieu de dessiner',
              onclick: () => {
                if (this.penSeen) {
                  this.penSeen = false;
                  this.fingerDraws = true;
                } else {
                  this.fingerDraws = !this.fingerDraws;
                }
                save('penSeen', this.penSeen);
                save('fingerDraws', this.fingerDraws);
                toast(
                  this.fingerDraws && !this.penSeen
                    ? 'Le doigt dessine. Deux doigts pour défiler.'
                    : 'Le doigt fait défiler. Dessinez au stylet.',
                );
                this.renderDock();
              },
            },
            icon('hand'),
          )
        : null,
      ].filter(Boolean),
    );
  }

  settingsOf(tool) {
    const pen = PENS[tool];
    const saved = this.penSettings[tool] ?? {};
    // the fountain pen and the ballpoint share their color
    const colorKey = tool === 'ballpointPen' ? 'fountainPen' : tool;
    return {
      color: this.penSettings[colorKey]?.color ?? pen.colors[0],
      size: saved.size ?? pen.sizes[1],
    };
  }

  setTool(tool) {
    this.tool = tool;
    save('tool', tool);
    if (tool === 'fountainPen' || tool === 'ballpointPen') save('lastPen', tool);
    if (tool !== 'lasso') this.clearSelection();
    this.closePopover();
    this.renderDock();
    this.requestFrame();
  }

  closePopover() {
    this.popover?.remove();
    this.popover = null;
  }

  togglePopover() {
    if (this.popover) return this.closePopover();
    const tool = this.tool;
    const pen = PENS[tool];
    const content = [];

    if (pen) {
      const settings = this.settingsOf(tool);
      const update = (change) => {
        this.penSettings[tool] = { ...settings, ...change };
        if (tool === 'ballpointPen' && change.color !== undefined) {
          this.penSettings.fountainPen = { ...this.penSettings.fountainPen, color: change.color };
        }
        save('pens', this.penSettings);
        this.closePopover();
        this.renderDock();
        this.togglePopover();
      };
      content.push(
        h('div.label', {}, pen.name),
        tool === 'fountainPen' || tool === 'ballpointPen'
          ? h(
              'div.choice',
              {},
              ['fountainPen', 'ballpointPen'].map((kind) =>
                h(
                  'button' + (kind === tool ? '.selected' : ''),
                  {
                    onclick: () => {
                      this.setTool(kind);
                      this.togglePopover();
                    },
                  },
                  kind === 'fountainPen' ? 'Plume' : 'Bille',
                ),
              ),
            )
          : null,
        h(
          'div.swatches',
          {},
          pen.colors.map((color) =>
            h('button' + (color === settings.color ? '.selected' : ''), {
              style: { background: cssColor(color, 1) },
              'aria-label': 'Couleur',
              onclick: () => update({ color }),
            }),
          ),
        ),
        h(
          'div.sizes',
          {},
          pen.sizes.map((size) => {
            const thickness = Math.max(2, Math.min(16, size * (tool === 'highlighter' || tool === 'tape' ? 0.3 : 1.4)));
            return h(
              'button' + (size === settings.size ? '.selected' : ''),
              { onclick: () => update({ size }), 'aria-label': 'Taille' },
              h('i', {
                style: {
                  width: '34px',
                  height: thickness + 'px',
                  background: cssColor(settings.color, 1),
                },
              }),
            );
          }),
        ),
      );
    } else if (tool === 'eraser') {
      const update = (change) => {
        this.eraser = { ...this.eraser, ...change };
        save('eraser', this.eraser);
        this.closePopover();
        this.togglePopover();
      };
      content.push(
        h('div.label', {}, 'Gomme'),
        h(
          'div.choice',
          {},
          h(
            'button' + (this.eraser.partial ? '.selected' : ''),
            { onclick: () => update({ partial: true }) },
            'Partielle',
          ),
          h(
            'button' + (!this.eraser.partial ? '.selected' : ''),
            { onclick: () => update({ partial: false }) },
            'Trait entier',
          ),
        ),
        h(
          'div.sizes',
          {},
          ERASER_SIZES.map((size) =>
            h(
              'button' + (size === this.eraser.size ? '.selected' : ''),
              { onclick: () => update({ size }), 'aria-label': 'Taille' },
              h('i', {
                style: {
                  width: size + 'px',
                  height: size + 'px',
                  background: 'transparent',
                  border: '2px solid var(--text)',
                },
              }),
            ),
          ),
        ),
      );
    } else {
      return;
    }
    this.popover = h('div.popover', {}, content);
    this.element.append(this.popover);
  }

  setStatus(state) {
    const labels = {
      live: 'Synchronisé',
      catchingUp: 'Synchronisation…',
      offline: 'Hors ligne',
    };
    let label = labels[state] ?? state;
    if (state === 'live' && this.session?.hasPending) label = 'Envoi…';
    this.status.textContent = label;
    this.status.className = 'status ' + state;

    clearTimeout(this.offlineTimer);
    this.offlineBanner?.remove();
    if (state === 'offline' && this.loaded) {
      this.offlineTimer = setTimeout(() => {
        this.offlineBanner = h(
          'div.offline-banner',
          {},
          icon('cloudOff'),
          'Hors ligne · vos modifications seront envoyées à la reconnexion',
        );
        this.element.append(this.offlineBanner);
      }, 2500);
    }
  }

  renderPresence() {
    const users = new Map();
    for (const [from, presence] of this.presences) {
      if (!users.has(presence.user)) users.set(presence.user, colorOf(from));
    }
    this.presenceEl.replaceChildren(
      ...[...users].slice(0, 4).map(([user, color]) =>
        h('span', { style: { background: color }, title: user }, initials(user)),
      ),
    );
  }

  updateUndoButtons() {
    this.undoButton.disabled = !this.undoStack.length;
    this.redoButton.disabled = !this.redoStack.length;
  }

  // Sync

  get pendingKey() {
    return 'noteplus.pending.' + (this.options.share ?? this.options.path);
  }

  connect() {
    const session = new Session({
      url: Api.webSocketUrl,
      token: Api.token,
      room: this.options.path,
      share: this.options.share,
      clientId: Api.clientId,
      create: !!this.options.create,
    });
    this.session = session;
    session.on('op', (op) => {
      this.note.apply(op);
      this.afterRemoteChange();
    });
    session.on('state', (state) => this.setStatus(state));
    session.on('ack', () => {
      this.savePending();
      if (!session.hasPending) this.setStatus(session.state);
    });
    session.on('synced', () => this.onSynced());
    session.on('presence', (from, user, presence) => {
      if (presence) this.presences.set(from, { ...presence, user, seen: Date.now() });
      else this.presences.delete(from);
      this.renderPresence();
      this.requestFrame();
    });
    session.on('stopped', (reason) => {
      if (reason === 'unauthorized') {
        Api.forget();
        toast('Votre session a expiré. Reconnectez-vous.');
      } else {
        toast("Ce carnet n'est plus disponible.");
      }
      this.close();
    });
    session.start();

    this.presenceTimer = setInterval(() => {
      const now = Date.now();
      let changed = false;
      for (const [from, presence] of this.presences) {
        if (now - presence.seen > 6000) {
          this.presences.delete(from);
          changed = true;
        }
      }
      if (changed) {
        this.renderPresence();
        this.requestFrame();
      }
    }, 1000);
  }

  onSynced() {
    if (!this.loaded) {
      this.loaded = true;
      this.loading.remove();
      // changes that couldn't be sent before the page was closed
      try {
        const saved = localStorage.getItem(this.pendingKey);
        if (saved) {
          const { ops } = deserialize(unbase64(saved));
          for (const op of ops) this.note.apply(op);
          this.session.submit(ops);
          localStorage.removeItem(this.pendingKey);
        }
      } catch {
        // nothing saved
      }
      // a new note gets its paper, which also adds it to the library
      if (this.options.create && this.session.seq === 0) {
        const paper = Ops.backgroundPattern(this.options.paper ?? '');
        this.note.apply(clone(paper));
        this.commit([paper], null, { undoable: false });
      }
      this.fitWidth();
    }
    this.afterRemoteChange();
  }

  afterRemoteChange() {
    if (this.selection && !this.note.pages.includes(this.selection.page)) this.clearSelection();
    this.requestFrame();
  }

  savePending() {
    try {
      if (!this.session.hasPending) {
        localStorage.removeItem(this.pendingKey);
      } else {
        localStorage.setItem(
          this.pendingKey,
          base64(serialize({ ops: [...this.session.pending.values()] })),
        );
      }
    } catch {
      // storage is full or unavailable
    }
  }

  /**
   * Sends `ops`, which are already applied here, and remembers `inverse`
   * so that the change can be undone.
   */
  commit(ops, inverse, { undoable = true } = {}) {
    if (!ops.length) return;
    this.session.submit(ops);
    this.savePending();
    if (this.session.state === 'live') this.setStatus('live');
    if (undoable && inverse) {
      this.undoStack.push({ ops, inverse });
      if (this.undoStack.length > 100) this.undoStack.shift();
      this.redoStack = [];
      this.updateUndoButtons();
    }
  }

  applyLocally(ops) {
    for (const op of ops) this.note.apply(clone(op));
    this.clearSelection();
    this.requestFrame();
  }

  undo() {
    const change = this.undoStack.pop();
    if (!change) return;
    this.applyLocally(change.inverse);
    this.session.submit(change.inverse);
    this.savePending();
    this.redoStack.push(change);
    this.updateUndoButtons();
  }

  redo() {
    const change = this.redoStack.pop();
    if (!change) return;
    this.applyLocally(change.ops);
    this.session.submit(change.ops);
    this.savePending();
    this.undoStack.push(change);
    this.updateUndoButtons();
  }

  // Layout

  resize() {
    const rect = this.element.getBoundingClientRect();
    this.width = rect.width;
    this.height = rect.height;
    this.canvas.width = Math.round(rect.width * this.dpr);
    this.canvas.height = Math.round(rect.height * this.dpr);
    this.headerHeight = this.element.querySelector('.editor-header').offsetHeight;
  }

  get fitZoom() {
    return Math.min((this.width - 16) / 1000, 1.25);
  }

  fitWidth() {
    const z = this.fitZoom;
    this.camera.z = z;
    this.camera.x = (1000 - this.width / z) / 2;
    this.camera.y = -(this.headerHeight + 12) / z;
    this.clampCamera();
    this.requestFrame();
  }

  /** The top of each page, in page units. */
  layout() {
    const tops = [];
    let y = 0;
    for (const page of this.note.pages) {
      tops.push(y);
      y += page.height + GAP;
    }
    this.pageTops = tops;
    this.contentHeight = y;
    return tops;
  }

  clampCamera() {
    const { z } = this.camera;
    const viewWidth = this.width / z;
    const viewHeight = this.height / z;
    if (viewWidth >= 1000) {
      this.camera.x = (1000 - viewWidth) / 2;
    } else {
      this.camera.x = Math.max(-20, Math.min(1000 + 20 - viewWidth, this.camera.x));
    }
    this.layout();
    const top = -(this.headerHeight + 12) / z;
    const bottom = this.contentHeight - viewHeight + 120 / z;
    this.camera.y = Math.max(top, Math.min(Math.max(top, bottom), this.camera.y));
  }

  toWorld(sx, sy) {
    return [this.camera.x + sx / this.camera.z, this.camera.y + sy / this.camera.z];
  }

  /** The page at the screen point, and the point on it. */
  pageAt(sx, sy, { nearest = false } = {}) {
    const [wx, wy] = this.toWorld(sx, sy);
    const tops = this.pageTops ?? this.layout();
    let best = null;
    for (let i = 0; i < this.note.pages.length; i++) {
      const page = this.note.pages[i];
      const top = tops[i];
      if (wy >= top && wy <= top + page.height && wx >= 0 && wx <= page.width) {
        return { page, index: i, x: wx, y: wy - top };
      }
      if (nearest) {
        const distance = Math.abs(wy - Math.min(Math.max(wy, top), top + page.height));
        if (!best || distance < best.distance) {
          best = { page, index: i, x: wx, y: wy - top, distance };
        }
      }
    }
    return best;
  }

  pageOffset(page) {
    const tops = this.pageTops ?? this.layout();
    return tops[this.note.pages.indexOf(page)] ?? 0;
  }

  /** The index of the page in the middle of the screen. */
  get currentPageIndex() {
    const [, wy] = this.toWorld(this.width / 2, this.height / 2);
    const tops = this.pageTops ?? this.layout();
    for (let i = tops.length - 1; i >= 0; i--) {
      if (wy >= tops[i] - GAP / 2) return i;
    }
    return 0;
  }

  scrollToPage(index) {
    this.layout();
    this.camera.y = this.pageTops[index] - (this.headerHeight + 12) / this.camera.z;
    this.clampCamera();
    this.requestFrame();
  }

  // Drawing

  requestFrame() {
    if (this.frameRequested || this.destroyed) return;
    this.frameRequested = true;
    requestAnimationFrame(() => {
      this.frameRequested = false;
      this.draw();
    });
  }

  invalidateAll() {
    for (const page of this.note.pages) page.changed();
  }

  /** A picture of `page` at about `scale` pixels per unit, kept until it changes. */
  cacheOf(page, scale) {
    const maxScale = Math.sqrt(MAX_CACHE_PIXELS / (page.width * page.height));
    const wanted = Math.min(scale, maxScale);
    let cache = this.caches.get(page);
    const stale =
      !cache ||
      cache.version !== page.version ||
      cache.hidden !== this.hiddenKey ||
      (!this.interacting && Math.abs(cache.scale - wanted) / wanted > 0.2);
    if (stale) {
      // while zooming, an outdated picture is redrawn at the old size first
      const s = cache && this.interacting && cache.version === page.version ? cache.scale : wanted;
      const canvas = cache?.canvas ?? document.createElement('canvas');
      canvas.width = Math.ceil(page.width * s);
      canvas.height = Math.ceil(page.height * s);
      const ctx = canvas.getContext('2d');
      ctx.setTransform(s, 0, 0, s, 0, 0);
      drawPage(ctx, this.note, page, {
        onImageLoad: () => {
          page.changed();
          this.requestFrame();
        },
        hidden: this.hidden,
      });
      cache = { canvas, version: page.version, scale: s, hidden: this.hiddenKey };
      this.caches.set(page, cache);
    }
    return cache;
  }

  draw() {
    if (this.destroyed) return;
    const ctx = this.ctx;
    const { x: cx, y: cy, z } = this.camera;
    const dpr = this.dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = this.deskColor;
    ctx.fillRect(0, 0, this.width, this.height);

    const tops = this.layout();
    const visible = new Set();

    this.note.pages.forEach((page, index) => {
      const top = tops[index];
      const sx = (0 - cx) * z;
      const sy = (top - cy) * z;
      const sw = page.width * z;
      const sh = page.height * z;
      if (sy > this.height || sy + sh < 0) return;
      visible.add(page);

      // the page's shadow
      ctx.save();
      ctx.shadowColor = 'rgba(20, 20, 40, 0.14)';
      ctx.shadowBlur = 14;
      ctx.shadowOffsetY = 3;
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(sx, sy, sw, sh);
      ctx.restore();

      const scale = z * dpr;
      const cache = this.cacheOf(page, scale);
      if (cache.scale >= scale * 0.8 || this.interacting) {
        ctx.drawImage(cache.canvas, sx, sy, sw, sh);
      } else {
        // zoomed in further than a picture of the whole page allows
        ctx.save();
        ctx.beginPath();
        ctx.rect(Math.max(0, sx), Math.max(0, sy), Math.min(this.width, sw), Math.min(this.height, sh));
        ctx.clip();
        ctx.translate(sx, sy);
        ctx.scale(z, z);
        drawPage(ctx, this.note, page, {
          onImageLoad: () => {
            page.changed();
            this.requestFrame();
          },
          hidden: this.hidden,
        });
        ctx.restore();
      }

      // the strokes being changed are drawn over the picture
      ctx.save();
      ctx.translate(sx, sy);
      ctx.scale(z, z);
      if (this.current?.page === page) {
        drawStroke(ctx, this.current.stroke);
      }
      if (this.selection?.page === page) {
        // while they move, they're left out of the page's picture
        if (this.hidden) for (const stroke of this.selection.strokes) drawStroke(ctx, stroke);
        this.drawSelection(ctx, z);
      }
      if (this.lasso?.page === page) this.drawLasso(ctx, z);
      for (const [from, presence] of this.presences) {
        if (presence.pg === page.id) this.drawCursor(ctx, presence, colorOf(from), z);
      }
      ctx.restore();

      if (page.bookmark !== null && page.bookmark !== undefined) {
        ctx.fillStyle = '#4f46e5';
        const bx = sx + sw - 34 * Math.min(1, z * 1.5);
        const bw = 18 * Math.min(1, z * 1.5);
        ctx.beginPath();
        ctx.moveTo(bx, sy);
        ctx.lineTo(bx + bw, sy);
        ctx.lineTo(bx + bw, sy + bw * 1.6);
        ctx.lineTo(bx + bw / 2, sy + bw * 1.15);
        ctx.lineTo(bx, sy + bw * 1.6);
        ctx.closePath();
        ctx.fill();
      }
    });

    // pictures of pages that went off screen are let go
    for (const page of this.caches.keys()) {
      if (!visible.has(page)) this.caches.delete(page);
    }

    if (this.eraserAt && this.tool === 'eraser') {
      const { sx, sy } = this.eraserAt;
      ctx.beginPath();
      ctx.arc(sx, sy, this.eraser.size * z, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255, 255, 255, 0.5)';
      ctx.fill();
      ctx.strokeStyle = 'rgba(30, 30, 40, 0.5)';
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }

    const pageCount = Math.max(1, this.note.pages.length - (this.note.pages.at(-1)?.isEmpty ? 1 : 0));
    const current = Math.min(this.currentPageIndex + 1, this.note.pages.length);
    this.pagePill.innerHTML = icon('pages');
    this.pagePill.append(`${current} / ${Math.max(pageCount, current)}`);
    this.positionSelectionBar();
  }

  drawSelection(ctx, z) {
    const b = this.selection.bounds;
    ctx.save();
    ctx.lineWidth = 1.5 / z;
    ctx.strokeStyle = 'rgba(79, 70, 229, 0.9)';
    ctx.setLineDash([6 / z, 4 / z]);
    ctx.strokeRect(b.left, b.top, b.right - b.left, b.bottom - b.top);
    ctx.setLineDash([]);
    ctx.fillStyle = 'rgba(79, 70, 229, 0.06)';
    ctx.fillRect(b.left, b.top, b.right - b.left, b.bottom - b.top);
    // the handle that resizes the selection
    ctx.beginPath();
    ctx.arc(b.right, b.bottom, 10 / z, 0, Math.PI * 2);
    ctx.fillStyle = '#ffffff';
    ctx.fill();
    ctx.lineWidth = 3 / z;
    ctx.strokeStyle = '#4f46e5';
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(b.right, b.bottom, 4 / z, 0, Math.PI * 2);
    ctx.fillStyle = '#4f46e5';
    ctx.fill();
    ctx.restore();
  }

  drawLasso(ctx, z) {
    const points = this.lasso.points;
    if (points.length < 2) return;
    ctx.save();
    ctx.beginPath();
    points.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    ctx.closePath();
    ctx.fillStyle = 'rgba(79, 70, 229, 0.08)';
    ctx.fill();
    ctx.setLineDash([8 / z, 6 / z]);
    ctx.lineWidth = 2 / z;
    ctx.strokeStyle = '#4f46e5';
    ctx.stroke();
    ctx.restore();
  }

  drawCursor(ctx, presence, color, z) {
    const s = 1 / z;
    ctx.save();
    ctx.translate(presence.x, presence.y);
    ctx.scale(s, s);
    ctx.beginPath();
    ctx.arc(0, 0, presence.down ? 7 : 6, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.lineWidth = 2.5;
    ctx.strokeStyle = '#fff';
    ctx.stroke();
    ctx.font = '600 12px -apple-system, system-ui, sans-serif';
    const width = ctx.measureText(presence.user).width + 16;
    ctx.fillStyle = color;
    roundRect(ctx, 8, 10, width, 22, 8);
    ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.fillText(presence.user, 16, 25);
    ctx.restore();
  }

  // Input

  onPointerDown(e) {
    e.preventDefault();
    this.canvas.setPointerCapture?.(e.pointerId);
    this.closePopover();
    const point = { x: e.offsetX, y: e.offsetY, type: e.pointerType, start: performance.now(), sx: e.offsetX, sy: e.offsetY };
    this.pointers.set(e.pointerId, point);

    if (e.pointerType === 'pen' && !this.penSeen) {
      this.penSeen = true;
      save('penSeen', true);
      this.renderDock();
    }

    const touches = [...this.pointers.values()].filter((p) => p.type === 'touch');
    if (e.pointerType === 'touch' && touches.length >= 2) {
      // a second finger: it's a pinch, not a stroke
      if (this.gesture?.byTouch) this.cancelGesture();
      this.startPinch();
      return;
    }

    const draws =
      e.pointerType === 'pen' ||
      (e.pointerType === 'mouse' && e.button === 0) ||
      (e.pointerType === 'touch' && this.fingerDraws && !this.penSeen);
    if (draws && !this.gesture) {
      this.startTool(e, point);
    } else if (e.pointerType === 'touch' || e.button === 1 || e.button === 2) {
      this.startPan(e.pointerId);
    }
  }

  onPointerMove(e) {
    const point = this.pointers.get(e.pointerId);
    if (this.tool === 'eraser' && (e.pointerType !== 'touch' || this.gesture?.pointerId === e.pointerId)) {
      this.eraserAt = { sx: e.offsetX, sy: e.offsetY };
      this.requestFrame();
    }
    if (!point) return;
    point.x = e.offsetX;
    point.y = e.offsetY;
    const gesture = this.gesture;
    if (!gesture) return;

    if (gesture.kind === 'pinch') return this.movePinch();
    if (gesture.kind === 'pan') return this.movePan(e.pointerId);
    if (gesture.pointerId !== e.pointerId) return;

    const events = e.getCoalescedEvents?.() ?? [e];
    for (const event of events.length ? events : [e]) {
      this.moveTool(event);
    }
  }

  onPointerUp(e, cancelled = false) {
    const point = this.pointers.get(e.pointerId);
    this.pointers.delete(e.pointerId);
    if (e.pointerType !== 'touch' && e.pointerType !== 'pen') {
      // a mouse keeps showing the eraser
    } else if (this.eraserAt) {
      this.eraserAt = null;
      this.requestFrame();
    }
    const gesture = this.gesture;

    // quick taps with two or three fingers undo and redo
    if (point?.type === 'touch' && gesture?.kind === 'pinch' && !gesture.moved) {
      const elapsed = performance.now() - gesture.start;
      if (this.pointers.size === 0 && elapsed < 300) {
        if (gesture.fingers === 2) this.undo();
        if (gesture.fingers >= 3) this.redo();
      }
    }

    if (!gesture) return;
    if (gesture.kind === 'pinch') {
      if (this.pointers.size === 0) {
        this.gesture = null;
        this.interacting = false;
        this.requestFrame();
      } else if (this.pointers.size === 1 && gesture.moved) {
        // the finger left on the screen carries on scrolling
        this.gesture = null;
        this.interacting = false;
        this.startPan([...this.pointers.keys()][0]);
      }
      // otherwise it may still be a tap with several fingers
      return;
    }
    if (gesture.kind === 'pan') {
      if (gesture.pointerId === e.pointerId) this.endPan();
      return;
    }
    if (gesture.pointerId !== e.pointerId) return;
    if (cancelled) this.cancelGesture();
    else this.endTool(e);
  }

  onWheel(e) {
    e.preventDefault();
    if (e.ctrlKey || e.metaKey) {
      this.zoomAt(e.offsetX, e.offsetY, Math.exp(-e.deltaY / 200));
    } else {
      this.camera.x += e.deltaX / this.camera.z;
      this.camera.y += e.deltaY / this.camera.z;
      this.clampCamera();
    }
    this.requestFrame();
  }

  onKeyDown(e) {
    if (e.target.closest?.('input, textarea')) return;
    const mod = e.metaKey || e.ctrlKey;
    if (mod && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      if (e.shiftKey) this.redo();
      else this.undo();
    } else if (mod && e.key.toLowerCase() === 'y') {
      e.preventDefault();
      this.redo();
    } else if ((e.key === 'Delete' || e.key === 'Backspace') && this.selection) {
      this.deleteSelection();
    } else if (e.key === 'Escape') {
      this.clearSelection();
    } else if (!mod) {
      const tools = { p: 'fountainPen', b: 'ballpointPen', c: 'pencil', h: 'highlighter', e: 'eraser', l: 'lasso', t: 'tape' };
      if (tools[e.key]) this.setTool(tools[e.key]);
    }
  }

  zoomAt(sx, sy, factor) {
    const [wx, wy] = this.toWorld(sx, sy);
    const z = Math.max(this.fitZoom * 0.5, Math.min(this.fitZoom * 8, this.camera.z * factor));
    this.camera.z = z;
    this.camera.x = wx - sx / z;
    this.camera.y = wy - sy / z;
    this.clampCamera();
  }

  startPan(pointerId) {
    cancelAnimationFrame(this.inertia);
    const point = this.pointers.get(pointerId);
    this.gesture = { kind: 'pan', pointerId, last: [point.x, point.y], velocity: [0, 0], time: performance.now() };
  }

  movePan(pointerId) {
    const gesture = this.gesture;
    if (gesture.pointerId !== pointerId) return;
    const point = this.pointers.get(pointerId);
    const dx = point.x - gesture.last[0];
    const dy = point.y - gesture.last[1];
    const now = performance.now();
    const dt = Math.max(1, now - gesture.time);
    gesture.velocity = [dx / dt, dy / dt];
    gesture.time = now;
    gesture.last = [point.x, point.y];
    this.camera.x -= dx / this.camera.z;
    this.camera.y -= dy / this.camera.z;
    this.clampCamera();
    this.requestFrame();
  }

  endPan() {
    const [vx, vy] = this.gesture.velocity;
    const lastMove = this.gesture.time;
    this.gesture = null;
    let velocity = [vx * 16, vy * 16];
    const step = () => {
      velocity = [velocity[0] * 0.94, velocity[1] * 0.94];
      if (Math.hypot(...velocity) < 0.3) return;
      this.camera.x -= velocity[0] / this.camera.z;
      this.camera.y -= velocity[1] / this.camera.z;
      this.clampCamera();
      this.requestFrame();
      this.inertia = requestAnimationFrame(step);
    };
    // a finger that stopped before lifting doesn't throw the page
    if (performance.now() - lastMove < 80 && Math.hypot(vx, vy) > 0.15) {
      this.inertia = requestAnimationFrame(step);
    }
  }

  startPinch() {
    cancelAnimationFrame(this.inertia);
    const touches = [...this.pointers.values()].filter((p) => p.type === 'touch');
    const [a, b] = touches;
    const center = [(a.x + b.x) / 2, (a.y + b.y) / 2];
    this.gesture = {
      kind: 'pinch',
      fingers: Math.max(this.gesture?.fingers ?? 0, touches.length),
      start: this.gesture?.kind === 'pinch' ? this.gesture.start : performance.now(),
      moved: false,
      distance: Math.hypot(a.x - b.x, a.y - b.y),
      center,
      world: this.toWorld(...center),
      zoom: this.camera.z,
    };
    this.interacting = true;
  }

  movePinch() {
    const gesture = this.gesture;
    const touches = [...this.pointers.values()].filter((p) => p.type === 'touch');
    if (touches.length < 2) return;
    gesture.fingers = Math.max(gesture.fingers, touches.length);
    const [a, b] = touches;
    const distance = Math.hypot(a.x - b.x, a.y - b.y);
    const center = [(a.x + b.x) / 2, (a.y + b.y) / 2];
    if (Math.abs(distance - gesture.distance) > 8 || Math.hypot(center[0] - gesture.center[0], center[1] - gesture.center[1]) > 8) {
      gesture.moved = true;
    }
    const z = Math.max(this.fitZoom * 0.5, Math.min(this.fitZoom * 8, gesture.zoom * (distance / gesture.distance)));
    this.camera.z = z;
    this.camera.x = gesture.world[0] - center[0] / z;
    this.camera.y = gesture.world[1] - center[1] / z;
    this.clampCamera();
    this.requestFrame();
  }

  /** Throws away a gesture that turned out to be something else. */
  cancelGesture() {
    const gesture = this.gesture;
    this.gesture = null;
    if (!gesture) return;
    if (gesture.kind === 'stroke') {
      this.current = null;
    } else if (gesture.kind === 'erase') {
      // put back what was erased
      const page = gesture.page;
      for (const piece of gesture.pieces) page.strokes.splice(page.strokes.indexOf(piece), 1);
      for (const original of gesture.erased) page.insertStroke(original);
      page.changed();
    } else if (gesture.kind === 'lasso') {
      this.lasso = null;
    } else if (gesture.kind === 'move' || gesture.kind === 'resize') {
      // what was moved so far is kept
      this.gesture = gesture;
      this.endTool(null);
    }
    this.requestFrame();
  }

  startTool(e, point) {
    const hit = this.pageAt(point.x, point.y);
    const byTouch = e.pointerType === 'touch';

    if (this.tool === 'lasso') {
      if (this.selection) {
        const b = this.selection.bounds;
        const top = this.pageOffset(this.selection.page);
        const [wx, wy] = this.toWorld(point.x, point.y);
        const x = wx;
        const y = wy - top;
        const handleDistance = Math.hypot(x - b.right, y - b.bottom) * this.camera.z;
        if (handleDistance <= HANDLE_RADIUS) {
          this.gesture = { kind: 'resize', pointerId: e.pointerId, byTouch, anchor: [b.left, b.top], start: [b.right, b.bottom], factor: 1 };
          this.hideSelectionBar();
          return;
        }
        if (x >= b.left - 8 && x <= b.right + 8 && y >= b.top - 8 && y <= b.bottom + 8) {
          this.gesture = { kind: 'move', pointerId: e.pointerId, byTouch, last: [x, y], dx: 0, dy: 0 };
          this.moving = true;
          this.hideSelectionBar();
          return;
        }
      }
      this.clearSelection();
      if (!hit) return;
      this.lasso = { page: hit.page, points: [[hit.x, hit.y]] };
      this.gesture = { kind: 'lasso', pointerId: e.pointerId, byTouch };
      return;
    }

    if (!hit) return;

    if (this.tool === 'eraser') {
      this.gesture = { kind: 'erase', pointerId: e.pointerId, byTouch, page: hit.page, erased: [], pieces: [], last: [hit.x, hit.y] };
      this.eraserAt = { sx: point.x, sy: point.y };
      this.eraseAt(hit.x, hit.y);
      this.sendPresence(hit.page, hit.x, hit.y, true);
      return;
    }

    const pen = PENS[this.tool];
    const settings = this.settingsOf(this.tool);
    const pressure = pen.pressure && e.pointerType === 'pen';
    let color = settings.color >>> 0;
    if (pen.alpha) color = ((pen.alpha << 24) | (color & 0xffffff)) >>> 0;
    const stroke = new Stroke({
      tool: pen.tool,
      color,
      pressureEnabled: pen.pressure,
      options: {
        s: settings.size,
        t: pen.options.t,
        sm: pen.options.sm,
        sl: pen.options.sl,
        sp: !pressure && pen.pressure,
        cs: true,
        ce: true,
        f: false,
        ...(pen.options.ts !== undefined ? { ts: pen.options.ts, te: pen.options.te } : {}),
      },
      points: [this.strokePoint(hit.x, hit.y, e, pressure)],
    });
    this.current = { page: hit.page, stroke, pressure };
    this.gesture = { kind: 'stroke', pointerId: e.pointerId, byTouch, page: hit.page };
    this.sendPresence(hit.page, hit.x, hit.y, true);
    this.requestFrame();
  }

  strokePoint(x, y, e, pressure) {
    return pressure ? [x, y, Math.max(0.05, e.pressure || 0.5)] : [x, y];
  }

  /** The point on `page` under the event. */
  pointOn(page, e) {
    const [wx, wy] = this.toWorld(e.offsetX, e.offsetY);
    return [wx, wy - this.pageOffset(page)];
  }

  moveTool(e) {
    const gesture = this.gesture;
    switch (gesture.kind) {
      case 'stroke': {
        const { page, stroke, pressure } = this.current;
        const [x, y] = this.pointOn(page, e);
        const last = stroke.points[stroke.points.length - 1];
        if (Math.hypot(x - last[0], y - last[1]) * this.camera.z < 0.75) return;
        stroke.points.push(this.strokePoint(x, y, e, pressure));
        stroke.invalidate();
        this.sendPresence(page, x, y, true);
        break;
      }
      case 'erase': {
        const [x, y] = this.pointOn(gesture.page, e);
        const [lx, ly] = gesture.last;
        // the eraser may have jumped over part of the page
        const steps = Math.min(50, Math.max(1, Math.ceil(Math.hypot(x - lx, y - ly) / (this.eraser.size / 2))));
        for (let i = 1; i <= steps; i++) {
          this.eraseAt(lx + ((x - lx) * i) / steps, ly + ((y - ly) * i) / steps);
        }
        gesture.last = [x, y];
        this.sendPresence(gesture.page, x, y, true);
        break;
      }
      case 'lasso': {
        const [x, y] = this.pointOn(this.lasso.page, e);
        this.lasso.points.push([x, y]);
        break;
      }
      case 'move': {
        const [x, y] = this.pointOn(this.selection.page, e);
        const dx = x - gesture.last[0];
        const dy = y - gesture.last[1];
        gesture.last = [x, y];
        gesture.dx += dx;
        gesture.dy += dy;
        for (const stroke of this.selection.strokes) stroke.shift(dx, dy);
        this.selection.bounds = boundsOfAll(this.selection.strokes);
        this.hidden = new Set(this.selection.strokes);
        this.hiddenKey = 'move';
        break;
      }
      case 'resize': {
        const [x, y] = this.pointOn(this.selection.page, e);
        const [ax, ay] = gesture.anchor;
        const [sx, sy] = gesture.start;
        const start = [sx - ax, sy - ay];
        const current = [x - ax, y - ay];
        const lengthSquared = start[0] ** 2 + start[1] ** 2 || 1;
        const factor = Math.max(0.05, Math.min(20, (current[0] * start[0] + current[1] * start[1]) / lengthSquared));
        for (const stroke of this.selection.strokes) stroke.scale(ax, ay, factor / gesture.factor);
        gesture.factor = factor;
        this.selection.bounds = boundsOfAll(this.selection.strokes);
        this.hidden = new Set(this.selection.strokes);
        this.hiddenKey = 'resize';
        break;
      }
    }
    this.requestFrame();
  }

  endTool(e) {
    const gesture = this.gesture;
    this.gesture = null;
    switch (gesture?.kind) {
      case 'stroke': {
        const { page, stroke } = this.current;
        this.current = null;
        this.sendPresence(page, ...stroke.points.at(-1).slice(0, 2), false);
        const b = boundsOfPoints(stroke.points);
        const isTap = Math.max(b.right - b.left, b.bottom - b.top) < 4;
        if (isTap) {
          const tape = tapeAt(page.strokes, stroke.points[0][0], stroke.points[0][1]);
          if (tape) {
            tape.revealed = !tape.revealed;
            page.changed();
            break;
          }
        }
        stroke.options.f = true;
        if (stroke.tool === Tools.tape && isStraightLine(stroke)) straighten(stroke);
        stroke.invalidate();
        page.insertStroke(stroke);
        this.note.ensureBlankLastPage();
        this.commit([Ops.addStroke(page, stroke)], [Ops.removeStrokes([stroke])]);
        break;
      }
      case 'erase': {
        const { page, erased, pieces } = gesture;
        this.sendPresence(page, ...gesture.last, false);
        if (!erased.length) break;
        this.note.ensureBlankLastPage();
        if (!pieces.length) {
          this.commit(
            [Ops.removeStrokes(erased)],
            erased.map((stroke) => Ops.addStroke(page, stroke)),
          );
        } else {
          this.commit(
            [Ops.removeStrokes(erased), ...pieces.map((stroke) => Ops.addStroke(page, stroke))],
            [Ops.removeStrokes(pieces), ...erased.map((stroke) => Ops.addStroke(page, stroke))],
          );
        }
        break;
      }
      case 'lasso': {
        const { page, points } = this.lasso;
        this.lasso = null;
        if (points.length < 3) break;
        const strokes = strokesInLasso(page.strokes, points);
        if (strokes.length) {
          this.selection = { page, strokes, bounds: boundsOfAll(strokes) };
          this.showSelectionBar();
        }
        break;
      }
      case 'move': {
        this.moving = false;
        this.hidden = null;
        this.hiddenKey = null;
        this.selection.page.changed();
        const { strokes } = this.selection;
        if (Math.abs(gesture.dx) + Math.abs(gesture.dy) > 0.01) {
          this.commit(
            [Ops.moveStrokes(strokes, gesture.dx, gesture.dy)],
            [Ops.moveStrokes(strokes, -gesture.dx, -gesture.dy)],
          );
        }
        this.showSelectionBar();
        break;
      }
      case 'resize': {
        this.hidden = null;
        this.hiddenKey = null;
        this.selection.page.changed();
        const { strokes } = this.selection;
        const [ax, ay] = gesture.anchor;
        if (gesture.factor !== 1) {
          this.commit(
            [Ops.scaleStrokes(strokes, ax, ay, gesture.factor)],
            [Ops.scaleStrokes(strokes, ax, ay, 1 / gesture.factor)],
          );
        }
        this.showSelectionBar();
        break;
      }
    }
    this.requestFrame();
  }

  /** Erases what's under the eraser at (x, y) on the page being erased. */
  eraseAt(x, y) {
    const gesture = this.gesture;
    const page = gesture.page;
    const strokes = page.strokes;
    let changed = false;
    for (let i = strokes.length - 1; i >= 0; i--) {
      const stroke = strokes[i];
      let pieces;
      if (this.eraser.partial) {
        pieces = erasedAround(stroke, x, y, this.eraser.size);
      } else {
        pieces = erasedAround(stroke, x, y, this.eraser.size) ? [] : null;
      }
      if (!pieces) continue;
      changed = true;
      strokes.splice(i, 1, ...pieces);
      const pieceIndex = gesture.pieces.indexOf(stroke);
      if (pieceIndex >= 0) gesture.pieces.splice(pieceIndex, 1);
      else gesture.erased.push(stroke);
      gesture.pieces.push(...pieces);
    }
    if (changed) {
      page.changed();
      this.requestFrame();
    }
  }

  sendPresence(page, x, y, down) {
    const now = performance.now();
    if (down && now - (this.lastPresence ?? 0) < 60) return;
    this.lastPresence = now;
    this.session.sendPresence({ pg: page.id, x, y, down });
  }

  // Selection

  clearSelection() {
    if (!this.selection) return;
    this.selection = null;
    this.moving = false;
    this.hideSelectionBar();
    this.requestFrame();
  }

  hideSelectionBar() {
    this.selectionBar?.remove();
    this.selectionBar = null;
  }

  showSelectionBar() {
    this.hideSelectionBar();
    this.selectionBar = h(
      'div.selection-bar',
      {},
      h('button', { onclick: () => this.recolorSelection() }, icon('palette'), 'Couleur'),
      h('button', { onclick: () => this.duplicateSelection() }, icon('copy'), 'Dupliquer'),
      h('button', { onclick: () => this.deleteSelection() }, icon('trash'), 'Supprimer'),
    );
    this.element.append(this.selectionBar);
    this.positionSelectionBar();
  }

  positionSelectionBar() {
    if (!this.selectionBar || !this.selection) return;
    const b = this.selection.bounds;
    const top = this.pageOffset(this.selection.page);
    const z = this.camera.z;
    const x = ((b.left + b.right) / 2 - this.camera.x) * z;
    let y = (top + b.top - this.camera.y) * z - 12;
    y = Math.max(this.headerHeight + 56, y);
    const half = (this.selectionBar.offsetWidth || 280) / 2;
    this.selectionBar.style.left = Math.max(half + 8, Math.min(this.width - half - 8, x)) + 'px';
    this.selectionBar.style.top = y + 'px';
  }

  deleteSelection() {
    const { page, strokes } = this.selection;
    for (const stroke of strokes) page.strokes.splice(page.strokes.indexOf(stroke), 1);
    page.changed();
    this.clearSelection();
    this.note.ensureBlankLastPage();
    this.commit([Ops.removeStrokes(strokes)], strokes.map((stroke) => Ops.addStroke(page, stroke)));
  }

  duplicateSelection() {
    const { page, strokes } = this.selection;
    const copies = strokes.map((stroke) => {
      const copy = stroke.copy({ id: newId() });
      copy.shift(24, 24);
      page.insertStroke(copy);
      return copy;
    });
    this.commit(copies.map((stroke) => Ops.addStroke(page, stroke)), [Ops.removeStrokes(copies)]);
    this.selection = { page, strokes: copies, bounds: boundsOfAll(copies) };
    this.showSelectionBar();
    this.requestFrame();
  }

  async recolorSelection() {
    const color = await sheet((close) => [
      h('h2', {}, 'Couleur'),
      h(
        'div.swatches',
        { style: { margin: '8px 0 6px' } },
        COLORS.map((c) => h('button', { style: { background: cssColor(c, 1) }, onclick: () => close(c) })),
      ),
    ]);
    if (color === undefined || !this.selection) return;
    const { page, strokes } = this.selection;
    const before = strokes.map((stroke) => [stroke, stroke.color]);
    const after = strokes.map((stroke) => {
      // highlighters keep their transparency
      const alpha = stroke.tool === Tools.highlighter ? stroke.color & 0xff000000 : 0xff000000;
      return [stroke, ((alpha | (color & 0xffffff)) >>> 0)];
    });
    for (const [stroke, c] of after) {
      stroke.color = c;
      stroke.invalidate();
    }
    page.changed();
    this.commit([Ops.colorStrokes(after)], [Ops.colorStrokes(before)]);
    this.requestFrame();
  }

  // Pages and menus

  addPageAfter(index) {
    const after = this.note.pages[index];
    const page = new Page(newId());
    const op = Ops.insertPage(page, after?.id);
    this.note.apply(clone(op));
    this.commit([op], [Ops.deletePage(page)]);
    this.scrollToPage(index + 1);
    toast(`Page ${index + 2} ajoutée`);
  }

  setBackground(pattern) {
    const previous = this.note.backgroundPattern;
    if (previous === pattern) return;
    const op = Ops.backgroundPattern(pattern);
    this.note.apply(clone(op));
    this.commit([op], [Ops.backgroundPattern(previous)]);
    this.requestFrame();
  }

  toggleBookmark(index) {
    const page = this.note.pages[index];
    const before = Ops.bookmark(page);
    page.bookmark = page.bookmark === null || page.bookmark === undefined ? '' : null;
    page.changed();
    this.commit([Ops.bookmark(page)], [before]);
    toast(page.bookmark === null ? 'Signet retiré' : `Page ${index + 1} ajoutée au sommaire`);
    this.requestFrame();
  }

  async showMenu() {
    const index = this.currentPageIndex;
    const page = this.note.pages[index];
    const bookmarked = page?.bookmark !== null && page?.bookmark !== undefined;
    const choice = await sheet((close) => [
      h('h2', {}, this.options.name),
      h(
        'div.menu',
        {},
        h('button', { onclick: () => close('pages') }, icon('pages'), 'Pages et sommaire'),
        h('button', { onclick: () => close('add') }, icon('plus'), 'Ajouter une page', h('span.hint', {}, `après la ${index + 1}`)),
        h('button', { onclick: () => close('bookmark') }, icon('bookmark', { filled: bookmarked }), bookmarked ? 'Retirer le signet' : 'Ajouter un signet'),
        h('button', { onclick: () => close('paper') }, icon('paper'), 'Fond de page'),
        this.options.share
          ? null
          : h('button', { onclick: () => close('share') }, icon('share'), 'Partager'),
        h('button', { onclick: () => close('fit') }, icon('notebook'), 'Ajuster à la largeur'),
      ),
    ]);
    if (choice === 'pages') this.showPages();
    if (choice === 'add') this.addPageAfter(index);
    if (choice === 'bookmark') this.toggleBookmark(index);
    if (choice === 'paper') this.showPapers();
    if (choice === 'share') copyShareLink(this.options.path);
    if (choice === 'fit') this.fitWidth();
  }

  async showPapers() {
    const choice = await sheet((close) => [
      h('h2', {}, 'Fond de page'),
      h('p', {}, "S'applique à toutes les pages du carnet."),
      h(
        'div.papers',
        {},
        [...PAPERS, { pattern: 'college', name: 'Marge' }, { pattern: 'cornell', name: 'Cornell' }].map((paper) =>
          h(
            'button.paper-choice' + (paper.pattern === this.note.backgroundPattern ? '.selected' : ''),
            { onclick: () => close(paper.pattern) },
            h('div.swatch' + (paper.pattern ? '.paper-' + paper.pattern : '')),
            paper.name,
          ),
        ),
      ),
    ]);
    if (choice !== undefined) this.setBackground(choice);
  }

  async showPages() {
    const current = this.currentPageIndex;
    const pages = this.note.pages;
    const choice = await sheet((close) => {
      const contents = pages
        .map((page, index) => ({ page, index }))
        .filter(({ page }) => page.bookmark !== null && page.bookmark !== undefined);
      return [
        h('h2', {}, 'Pages'),
        contents.length
          ? h(
              'div.contents',
              {},
              contents.map(({ page, index }) =>
                h(
                  'button',
                  { onclick: () => close({ go: index }) },
                  h('span', { style: { color: 'var(--brand)' } }, icon('bookmark', { filled: true })),
                  page.bookmark || `Page ${index + 1}`,
                  h('span.num', {}, String(index + 1)),
                ),
              ),
            )
          : null,
        h(
          'div.pages',
          {},
          pages.map((page, index) => {
            const thumb = document.createElement('canvas');
            const scale = 0.12;
            thumb.width = page.width * scale * this.dpr;
            thumb.height = page.height * scale * this.dpr;
            const ctx = thumb.getContext('2d');
            ctx.setTransform(scale * this.dpr, 0, 0, scale * this.dpr, 0, 0);
            drawPage(ctx, this.note, page, {});
            const bookmarked = page.bookmark !== null && page.bookmark !== undefined;
            return h(
              'button.page-thumb' + (index === current ? '.current' : ''),
              { onclick: () => close({ go: index }) },
              thumb,
              h('span', {}, bookmarked ? h('span.bookmark', {}, '▾ ') : null, String(index + 1)),
            );
          }),
          h(
            'button.page-thumb.add',
            { onclick: () => close({ add: true }) },
            h('div.blank', {}, icon('plus')),
            'Ajouter',
          ),
        ),
      ];
    });
    if (choice?.go !== undefined) this.scrollToPage(choice.go);
    if (choice?.add) this.addPageAfter(Math.max(0, pages.length - 2));
  }

  close() {
    if (this.destroyed) return;
    this.destroy();
    this.options.onClose();
  }

  destroy() {
    this.destroyed = true;
    this.savePending();
    this.session?.close();
    clearInterval(this.presenceTimer);
    clearTimeout(this.offlineTimer);
    cancelAnimationFrame(this.inertia);
    window.removeEventListener('resize', this.onResize);
    window.removeEventListener('beforeunload', this.onBeforeUnload);
    document.removeEventListener('keydown', this.onKey);
    document.removeEventListener('gesturestart', this.onGesture);
    document.removeEventListener('gesturechange', this.onGesture);
  }
}

function boundsOfPoints(points) {
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

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** A copy of `op` as it would come back from the server. */
function clone(op) {
  return deserialize(serialize(op));
}

export { prompt, confirm, errorMessage, boundsOf, smoothPath, strokePolygon };
