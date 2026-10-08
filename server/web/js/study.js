// Flashcards, like `lib/pages/editor/study.dart` and `study_state.dart` in
// the app: each page of a note in flashcards mode is a card, with the
// question in its top half and the answer in its bottom half.

import { drawPage } from './render.js';
import { h, icon } from './ui.js';

const DAY = 24 * 60 * 60 * 1000;
const INITIAL_EASE = 2.5;
const MIN_EASE = 1.3;
const AGAIN_DELAY = 10 * 60 * 1000;

export const GRADES = ['again', 'hard', 'good', 'easy'];

const unseen = { d: 0, i: 0, e: INITIAL_EASE, r: 0, l: 0 };

export function isDue(state, now = Date.now()) {
  return (state ?? unseen).d <= now;
}

/** How long until a card graded `grade` is shown again, in milliseconds. */
export function nextInterval(state, grade) {
  const s = state ?? unseen;
  let days;
  switch (grade) {
    case 'again':
      return AGAIN_DELAY;
    case 'hard':
      days = s.r === 0 ? 1 : s.i * 1.2;
      break;
    case 'good':
      days = s.r === 0 ? 1 : s.r === 1 ? 3 : s.i * s.e;
      break;
    case 'easy':
      days = s.r === 0 ? 4 : s.i * s.e * 1.3;
      break;
  }
  const minutes = Math.round(Math.min(3650, Math.max(1, days)) * 24 * 60);
  return minutes * 60 * 1000;
}

/** The state of a card after it was graded `grade` at `now`. */
export function graded(state, grade, now = Date.now()) {
  const s = state ?? unseen;
  const interval = nextInterval(s, grade);
  const easeChange = { again: -0.2, hard: -0.15, good: 0, easy: 0.15 }[grade];
  return {
    d: now + interval,
    i: grade === 'again' ? 0 : Math.round(interval / 60000) / (24 * 60),
    e: Math.min(4, Math.max(MIN_EASE, (s.e ?? INITIAL_EASE) + easeChange)),
    r: grade === 'again' ? 0 : (s.r ?? 0) + 1,
    l: grade === 'again' ? (s.l ?? 0) + 1 : (s.l ?? 0),
  };
}

/** A short description of a delay, like the app's grade buttons. */
export function describe(ms) {
  const minutes = ms / 60000;
  if (minutes < 60 * 24) return `${Math.round(minutes)} min`;
  const days = minutes / (60 * 24);
  if (days < 30) return `${Math.round(days)} j`;
  if (days < 365) return `${Math.round(days / 30)} mois`;
  return `${Math.round(days / 365)} an(s)`;
}

const LABELS = { again: 'À revoir', hard: 'Difficile', good: 'Bien', easy: 'Facile' };

/**
 * Shows the cards of `note` one at a time.
 * `onGraded(page)` is called after a card's study state changed.
 */
export function study(note, { onGraded, dpr = window.devicePixelRatio || 1 }) {
  const cards = note.pages.filter((page) => !page.isEmpty);
  let queue = cards.filter((page) => isDue(page.study));
  let total = queue.length;
  let studied = 0;
  let revealed = false;

  const scrim = h('div.study');
  const close = () => {
    scrim.classList.add('closing');
    setTimeout(() => scrim.remove(), 180);
    document.removeEventListener('keydown', onKey);
  };
  const onKey = (event) => {
    if (event.key === 'Escape') close();
    if (!queue.length) return;
    if (!revealed && (event.key === ' ' || event.key === 'Enter')) {
      revealed = true;
      render();
    } else if (revealed && ['1', '2', '3', '4'].includes(event.key)) {
      grade(GRADES[Number(event.key) - 1]);
    }
  };
  document.addEventListener('keydown', onKey);

  function half(page, answer) {
    const width = Math.min(560, window.innerWidth - 40);
    const scale = width / page.width;
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round((page.height / 2) * scale * dpr);
    canvas.style.width = width + 'px';
    const ctx = canvas.getContext('2d');
    ctx.setTransform(scale * dpr, 0, 0, scale * dpr, 0, answer ? -(page.height / 2) * scale * dpr : 0);
    drawPage(ctx, note, page, { onImageLoad: () => render() });
    return h('div.card-half' + (answer ? '.answer' : ''), {}, canvas);
  }

  function grade(value) {
    const page = queue.shift();
    page.study = graded(page.study, value);
    onGraded(page);
    if (value === 'again') queue.push(page);
    else studied++;
    revealed = false;
    render();
  }

  function render() {
    const header = h(
      'div.study-header',
      {},
      h('button.icon-btn', { onclick: close, 'aria-label': 'Fermer' }, icon('close')),
      h('strong', {}, 'Réviser'),
      h('span.progress', {}, queue.length ? `${studied} / ${total}` : ''),
    );

    let body;
    if (!queue.length) {
      const message = !cards.length
        ? "Ce carnet n'a pas encore de fiche. Écrivez une question dans la moitié haute d'une page et sa réponse dans la moitié basse."
        : studied
          ? `Fiches révisées : ${studied}`
          : 'Les prochaines fiches arriveront quand il sera temps de les revoir.';
      body = h(
        'div.study-done',
        {},
        h('div.art', {}, icon(studied ? 'check' : 'sparkles')),
        h('h2', {}, !cards.length ? 'Aucune fiche' : studied ? 'Terminé !' : 'Rien à réviser pour le moment'),
        h('p', {}, message),
        cards.length
          ? h(
              'button.btn' + (studied ? '' : '.primary'),
              {
                onclick: () => {
                  queue = [...cards];
                  total = queue.length;
                  studied = 0;
                  render();
                },
              },
              'Réviser toutes les fiches',
            )
          : null,
        h('button.btn.ghost', { onclick: close }, 'Fermer'),
      );
    } else {
      const page = queue[0];
      body = h(
        'div.study-card',
        {},
        h('div.card', {}, half(page, false), revealed ? half(page, true) : h('div.card-hidden', {}, '?')),
        revealed
          ? h(
              'div.grades',
              {},
              GRADES.map((value) =>
                h(
                  'button.grade.' + value,
                  { onclick: () => grade(value) },
                  h('strong', {}, LABELS[value]),
                  h('span', {}, describe(nextInterval(page.study, value))),
                ),
              ),
            )
          : h(
              'button.btn.primary.block',
              {
                onclick: () => {
                  revealed = true;
                  render();
                },
              },
              'Afficher la réponse',
            ),
      );
    }
    scrim.replaceChildren(header, body);
  }

  render();
  document.body.append(scrim);
}
