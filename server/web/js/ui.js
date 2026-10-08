// Small helpers to build the interface.

import { icon } from './icons.js';

/**
 * Creates an element: `h('button.icon-btn', {onclick}, children...)`.
 * Strings are text, except those starting with `<svg` which are icons.
 */
export function h(tag, props = {}, ...children) {
  const [name, ...classes] = tag.split('.');
  const element = document.createElement(name || 'div');
  if (classes.length) element.className = classes.join(' ');
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith('on')) element.addEventListener(key.slice(2), value);
    else if (key === 'style' && typeof value === 'object') Object.assign(element.style, value);
    else if (key === 'dataset') Object.assign(element.dataset, value);
    else if (key in element && key !== 'list') element[key] = value;
    else element.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    if (typeof child === 'string' && child.startsWith('<svg')) {
      element.insertAdjacentHTML('beforeend', child);
    } else {
      element.append(child);
    }
  }
  return element;
}

export { icon };

let toasts;

/** Shows `message` for a moment at the top of the screen. */
export function toast(message, duration = 2600) {
  toasts ??= document.body.appendChild(h('div.toasts'));
  const element = h('div.toast', {}, message);
  toasts.append(element);
  setTimeout(() => {
    element.style.transition = 'opacity 0.3s, transform 0.3s';
    element.style.opacity = '0';
    element.style.transform = 'translateY(-8px)';
    setTimeout(() => element.remove(), 300);
  }, duration);
}

/**
 * Shows a sheet (from the bottom on phones, centered on large screens),
 * built by `build(close)`. Returns a promise of the value given to `close`.
 */
export function sheet(build, { center = false, dismissible = true } = {}) {
  return new Promise((resolve) => {
    const scrim = h('div.scrim' + (center ? '.center' : ''));
    const close = (value) => {
      scrim.style.transition = 'opacity 0.18s';
      scrim.style.opacity = '0';
      setTimeout(() => scrim.remove(), 180);
      document.removeEventListener('keydown', onKey);
      resolve(value);
    };
    const onKey = (event) => {
      if (event.key === 'Escape' && dismissible) close(undefined);
    };
    const body = h('div.sheet', {}, center ? null : h('div.grabber'));
    body.append(...[build(close)].flat(Infinity).filter((child) => child !== null && child !== undefined && child !== false));
    scrim.append(body);
    scrim.addEventListener('pointerdown', (event) => {
      if (event.target === scrim && dismissible) close(undefined);
    });
    document.addEventListener('keydown', onKey);
    document.body.append(scrim);
    body.querySelector('input')?.focus();
  });
}

/** Asks a yes/no question, and returns whether the user confirmed. */
export function confirm({ title, message, action, danger = false }) {
  return sheet(
    (close) => [
      h('h2', {}, title),
      message ? h('p', {}, message) : null,
      h(
        'div.row',
        {},
        h('button.btn', { onclick: () => close(false) }, 'Annuler'),
        h(
          'button.btn.primary',
          {
            onclick: () => close(true),
            style: danger ? { background: 'var(--danger)', boxShadow: 'none' } : undefined,
          },
          action,
        ),
      ),
    ],
    { center: true },
  ).then((value) => value === true);
}

/** Asks for a line of text, and returns it, or undefined if cancelled. */
export function prompt({ title, message, value = '', placeholder = '', action = 'OK' }) {
  return sheet(
    (close) => {
      const input = h('input', { value, placeholder, enterKeyHint: 'done' });
      const submit = () => close(input.value.trim());
      input.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') submit();
      });
      return [
        h('h2', {}, title),
        message ? h('p', {}, message) : null,
        h('div.stack', {}, h('div.field', {}, input)),
        h(
          'div.row',
          { style: { marginTop: '14px' } },
          h('button.btn', { onclick: () => close(undefined) }, 'Annuler'),
          h('button.btn.primary', { onclick: submit }, action),
        ),
      ];
    },
    { center: true },
  );
}

export function initials(name) {
  return (name || '?').trim().charAt(0).toUpperCase() || '?';
}

const PRESENCE_COLORS = [
  '#e5484d', '#30a46c', '#0090ff', '#f76b15', '#8e4ec6', '#12a594', '#d6409f', '#978365',
];

/** The color of a collaborator, the same as in the app. */
export function colorOf(clientId) {
  let hash = 0;
  for (let i = 0; i < clientId.length; i++) {
    hash = (hash * 31 + clientId.charCodeAt(i)) & 0x7fffffff;
  }
  return PRESENCE_COLORS[hash % PRESENCE_COLORS.length];
}
