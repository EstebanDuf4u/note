// Question blocks: written in a sheet, placed on a page like a photo, and
// answered there or with all the others of the note in its quiz.

import { newQuiz, Stroke, Tools } from './model.js';
import { drawStroke, inkBounds, INK_WIDTH, QUIZ_LABELS } from './render.js';
import { describe, GRADES, graded, isDue, nextInterval } from './study.js';
import { h, icon, sheet, toast } from './ui.js';

const INK_HEIGHT = 170;
const GRADE_LABELS = { again: 'À revoir', hard: 'Difficile', good: 'Bien', easy: 'Facile' };
const TYPE_HINTS = {
  qa: 'Une question et sa réponse, cachée jusqu’à ce qu’on la demande.',
  tf: 'Une affirmation : est-elle vraie ou fausse ?',
  mcq: 'Plusieurs choix, dont un ou plusieurs bons.',
  cloze: 'Une phrase dont des mots sont cachés, à retrouver.',
};
const TYPE_NAMES = { qa: 'Question', tf: 'Vrai / Faux', mcq: 'QCM', cloze: 'À trous' };

/** `text` without case, accents or extra spaces, to compare answers. */
export function normalize(text) {
  return text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[.!?;:,]+$/, '');
}

/** How many letters to add, remove or change to go from `a` to `b`. */
function distance(a, b) {
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length];
}

/**
 * How `given` compares with `expected`: 'right', 'close' when it's off by
 * a typo in a long enough word, or 'wrong'.
 */
export function compareAnswer(given, expected) {
  const a = normalize(given);
  const b = normalize(expected);
  if (a === b) return 'right';
  return a && b.length >= 5 && distance(a, b) <= 1 ? 'close' : 'wrong';
}

/** The sentence of a cloze block, as text and the words to find. */
export function clozeParts(cloze) {
  const parts = cloze.split(/\[([^\]]*)\]/);
  return parts.map((part, i) => (i % 2 ? { answer: part } : { text: part }));
}

/** Whether `quiz` asks something and can be answered. */
export function quizProblem(quiz) {
  const asks = quiz.question.text.trim() || quiz.question.ink.length;
  switch (quiz.type) {
    case 'qa':
      if (!asks) return 'Écrivez la question.';
      if (!quiz.answer.text.trim() && !quiz.answer.ink.length) return 'Écrivez la réponse.';
      return null;
    case 'tf':
      return asks ? null : "Écrivez l'affirmation.";
    case 'mcq': {
      if (!asks) return 'Écrivez la question.';
      const filled = quiz.choices.filter((choice) => choice.text.trim());
      if (filled.length < 2) return 'Proposez au moins deux choix.';
      if (!filled.some((choice) => choice.correct)) return 'Cochez au moins une bonne réponse.';
      return null;
    }
    case 'cloze':
      return clozeParts(quiz.cloze).some((part) => part.answer?.trim())
        ? null
        : 'Mettez entre crochets au moins un mot à retrouver.';
  }
  return null;
}

// Handwriting

/** A pad to write on with a pen or a finger, for a question or an answer. */
function inkPad(ink) {
  const dpr = Math.min(window.devicePixelRatio || 1, 3);
  const canvas = h('canvas.ink-pad');
  canvas.width = INK_WIDTH * dpr;
  canvas.height = INK_HEIGHT * dpr;
  const ctx = canvas.getContext('2d');
  let current = null;
  let penSeen = false;

  const draw = () => {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // lines to write on
    ctx.strokeStyle = 'rgba(79, 70, 229, 0.14)';
    ctx.lineWidth = 1;
    for (let y = 42; y < INK_HEIGHT; y += 42) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(INK_WIDTH, y);
      ctx.stroke();
    }
    for (const stroke of ink) drawStroke(ctx, stroke);
    if (current) drawStroke(ctx, current);
  };
  const pointOf = (e) => {
    const rect = canvas.getBoundingClientRect();
    return [((e.clientX - rect.left) / rect.width) * INK_WIDTH, ((e.clientY - rect.top) / rect.height) * INK_HEIGHT];
  };

  canvas.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'pen') penSeen = true;
    // with a pen, the hand resting on the pad doesn't write
    if (current || (penSeen && e.pointerType === 'touch')) return;
    e.preventDefault();
    try {
      canvas.setPointerCapture(e.pointerId);
    } catch {
      // the pointer is already gone
    }
    current = new Stroke({
      tool: Tools.ballpointPen,
      color: 0xff17171f,
      pressureEnabled: false,
      options: { s: 4, t: 0.5, sm: 0, sl: 0.5, sp: false, cs: true, ce: true, f: false },
      points: [pointOf(e)],
    });
    current.pointerId = e.pointerId;
    draw();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (current?.pointerId !== e.pointerId) return;
    const events = e.getCoalescedEvents?.() ?? [];
    for (const event of events.length ? events : [e]) current.points.push(pointOf(event));
    current.invalidate();
    draw();
  });
  const end = (e) => {
    if (current?.pointerId !== e.pointerId) return;
    delete current.pointerId;
    current.options.f = true;
    current.invalidate();
    ink.push(current);
    current = null;
    draw();
  };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);
  for (const type of ['touchstart', 'touchmove']) {
    canvas.addEventListener(type, (e) => e.preventDefault(), { passive: false });
  }
  draw();

  return h(
    'div.ink-box',
    {},
    canvas,
    h(
      'div.ink-actions',
      {},
      h('button', {
        onclick: () => {
          ink.pop();
          draw();
        },
      }, icon('undo'), 'Annuler le trait'),
      h('button', {
        onclick: () => {
          ink.length = 0;
          draw();
        },
      }, icon('trash'), 'Tout effacer'),
    ),
  );
}

/** Some handwriting, as a picture as wide as the pad was. */
function inkView(ink) {
  const bounds = inkBounds(ink);
  if (!bounds) return null;
  const dpr = Math.min(window.devicePixelRatio || 1, 3);
  const height = bounds.bottom - bounds.top + 12;
  const canvas = h('canvas.ink-view');
  canvas.width = INK_WIDTH * dpr;
  canvas.height = height * dpr;
  canvas.style.aspectRatio = `${INK_WIDTH} / ${height}`;
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, (6 - bounds.top) * dpr);
  for (const stroke of ink) drawStroke(ctx, stroke);
  return canvas;
}

/** A text field, with a pad to write by hand instead or as well. */
function writingField(writing, { placeholder, label }) {
  const pad = h('div');
  const showPad = () => {
    pad.replaceChildren(inkPad(writing.ink));
    toggle.hidden = true;
  };
  const toggle = h('button.btn.ghost.small', { onclick: showPad }, icon('ballpoint'), 'Écrire à la main');
  const area = h('textarea.quiz-text', {
    rows: 2,
    placeholder,
    value: writing.text,
    oninput: (e) => {
      writing.text = e.target.value;
    },
  });
  if (writing.ink.length) showPad();
  return h('div.quiz-field', {}, h('div.sheet-label', {}, label), area, pad, toggle);
}

// Writing a question

/**
 * Lets the user write a question block, or change `existing`.
 * Returns the block's new contents, or undefined if they cancelled.
 */
export function editQuiz(existing) {
  const copy = (writing) => ({ text: writing.text, ink: [...writing.ink] });
  const draft = existing
    ? {
        ...existing,
        question: copy(existing.question),
        answer: copy(existing.answer),
        choices: existing.choices.map((choice) => ({ ...choice })),
      }
    : newQuiz({
        choices: [
          { text: '', correct: true },
          { text: '', correct: false },
          { text: '', correct: false },
        ],
      });

  return sheet((close) => {
    const body = h('div.stack');
    const render = () => {
      const types = h(
        'div.segmented.quiz-types',
        {},
        Object.entries(TYPE_NAMES).map(([type, name]) =>
          h(
            'button' + (draft.type === type ? '.selected' : ''),
            {
              onclick: () => {
                draft.type = type;
                render();
              },
            },
            name,
          ),
        ),
      );
      const fields = [];
      if (draft.type === 'cloze') {
        const preview = h('div.cloze-preview');
        const showPreview = () => {
          preview.replaceChildren(
            ...clozeParts(draft.cloze).map((part) =>
              part.answer !== undefined ? h('span.blank', {}, part.answer || '…') : part.text,
            ),
          );
        };
        fields.push(
          h(
            'div.quiz-field',
            {},
            h('div.sheet-label', {}, 'La phrase'),
            h('textarea.quiz-text', {
              rows: 3,
              placeholder: 'La mitose compte [4] phases.',
              value: draft.cloze,
              oninput: (e) => {
                draft.cloze = e.target.value;
                showPreview();
              },
            }),
            h('p.hint', {}, 'Mettez entre [crochets] les mots à retrouver.'),
            preview,
          ),
        );
        showPreview();
      } else {
        fields.push(
          writingField(draft.question, {
            label: draft.type === 'tf' ? "L'affirmation" : 'La question',
            placeholder: draft.type === 'tf' ? 'La mitose compte 4 phases.' : 'Combien de phases compte la mitose ?',
          }),
        );
      }
      if (draft.type === 'qa') {
        fields.push(writingField(draft.answer, { label: 'La réponse', placeholder: 'Quatre : prophase, métaphase, anaphase, télophase.' }));
      }
      if (draft.type === 'tf') {
        fields.push(
          h(
            'div.quiz-field',
            {},
            h('div.sheet-label', {}, 'La bonne réponse'),
            h(
              'div.segmented',
              {},
              [true, false].map((value) =>
                h(
                  'button' + (draft.truth === value ? '.selected' : ''),
                  {
                    onclick: () => {
                      draft.truth = value;
                      render();
                    },
                  },
                  value ? 'Vrai' : 'Faux',
                ),
              ),
            ),
          ),
        );
      }
      if (draft.type === 'mcq') {
        fields.push(
          h(
            'div.quiz-field',
            {},
            h('div.sheet-label', {}, 'Les choix · touchez ✓ pour les bonnes réponses'),
            draft.choices.map((choice, i) =>
              h(
                'div.choice-row',
                {},
                h(
                  'button.choice-check' + (choice.correct ? '.correct' : ''),
                  {
                    'aria-label': choice.correct ? 'Bonne réponse' : 'Mauvaise réponse',
                    onclick: () => {
                      choice.correct = !choice.correct;
                      render();
                    },
                  },
                  icon('check'),
                ),
                h('input.choice-input', {
                  value: choice.text,
                  placeholder: `Choix ${i + 1}`,
                  oninput: (e) => {
                    choice.text = e.target.value;
                  },
                }),
                draft.choices.length > 2
                  ? h(
                      'button.icon-btn.small',
                      {
                        'aria-label': 'Retirer ce choix',
                        onclick: () => {
                          draft.choices.splice(i, 1);
                          render();
                        },
                      },
                      icon('close'),
                    )
                  : null,
              ),
            ),
            draft.choices.length < 8
              ? h(
                  'button.btn.ghost.small',
                  {
                    onclick: () => {
                      draft.choices.push({ text: '', correct: false });
                      render();
                    },
                  },
                  icon('plus'),
                  'Ajouter un choix',
                )
              : null,
          ),
        );
      }
      body.replaceChildren(
        types,
        h('p.hint', {}, TYPE_HINTS[draft.type]),
        ...fields,
        h(
          'div.row',
          {},
          h('button.btn', { onclick: () => close(undefined) }, 'Annuler'),
          h(
            'button.btn.primary',
            {
              onclick: () => {
                const problem = quizProblem(draft);
                if (problem) return toast(problem);
                draft.choices = draft.choices.filter((choice) => choice.text.trim());
                close(draft);
              },
            },
            existing ? 'Enregistrer' : 'Ajouter',
          ),
        ),
      );
    };
    render();
    return [h('h2', {}, existing ? 'Modifier la question' : 'Nouvelle question'), body];
  });
}

// Answering

/**
 * A question to answer, as an element. `onResult(grade)` is called once
 * the user answered and knows whether they were right.
 */
export function answerCard(quiz, { onResult }) {
  const card = h('div.quiz-card');
  const question = () => [
    h('div.quiz-label', {}, h('span.mark', {}, '?'), QUIZ_LABELS[quiz.type]),
    quiz.type === 'cloze' ? null : quiz.question.text.trim() ? h('div.quiz-question', {}, quiz.question.text) : null,
    quiz.type === 'cloze' ? null : inkView(quiz.question.ink),
  ];
  const grades = () =>
    h(
      'div.grades',
      {},
      GRADES.map((value) =>
        h(
          'button.grade.' + value,
          { onclick: () => onResult(value) },
          h('strong', {}, GRADE_LABELS[value]),
          h('span', {}, describe(nextInterval(quiz.study, value))),
        ),
      ),
    );
  const verdict = (right, detail) =>
    h(
      'div.verdict' + (right ? '.right' : '.wrong'),
      {},
      icon(right ? 'check' : 'close'),
      h('div', {}, h('strong', {}, right ? 'Bonne réponse !' : 'Pas tout à fait'), detail ? h('span', {}, detail) : null),
    );
  const next = (right) =>
    h('button.btn.primary.block', { onclick: () => onResult(right ? 'good' : 'again') }, 'Continuer');

  const render = (state = {}) => {
    const parts = [...question()];
    switch (quiz.type) {
      case 'qa':
        if (!state.revealed) {
          parts.push(h('button.btn.primary.block', { onclick: () => render({ revealed: true }) }, 'Afficher la réponse'));
        } else {
          parts.push(
            h(
              'div.quiz-answer',
              {},
              h('div.sheet-label', {}, 'Réponse'),
              quiz.answer.text.trim() ? h('div', {}, quiz.answer.text) : null,
              inkView(quiz.answer.ink),
            ),
            h('p.hint', {}, 'Saviez-vous la réponse ?'),
            grades(),
          );
        }
        break;
      case 'tf':
        if (state.picked === undefined) {
          parts.push(
            h(
              'div.choices.two',
              {},
              [true, false].map((value) =>
                h('button.choice', { onclick: () => render({ picked: value }) }, value ? 'Vrai' : 'Faux'),
              ),
            ),
          );
        } else {
          const right = state.picked === quiz.truth;
          parts.push(
            h(
              'div.choices.two',
              {},
              [true, false].map((value) =>
                h(
                  'button.choice' + (value === quiz.truth ? '.correct' : value === state.picked ? '.wrong' : ''),
                  { disabled: true },
                  value ? 'Vrai' : 'Faux',
                ),
              ),
            ),
            verdict(right, right ? null : `C'était ${quiz.truth ? 'vrai' : 'faux'}.`),
            next(right),
          );
        }
        break;
      case 'mcq': {
        const picked = state.picked ?? new Set();
        const several = quiz.choices.filter((choice) => choice.correct).length > 1;
        const checked = state.checked;
        const right = quiz.choices.every((choice, i) => choice.correct === picked.has(i));
        if (several && !checked) parts.push(h('p.hint', {}, 'Plusieurs réponses possibles.'));
        parts.push(
          h(
            'div.choices',
            {},
            quiz.choices.map((choice, i) => {
              let mark = picked.has(i) ? '.picked' : '';
              if (checked) mark = choice.correct ? '.correct' : picked.has(i) ? '.wrong' : '';
              return h(
                'button.choice' + mark,
                {
                  disabled: checked,
                  onclick: () => {
                    const chosen = new Set(several ? picked : []);
                    if (picked.has(i) && several) chosen.delete(i);
                    else chosen.add(i);
                    render({ picked: chosen });
                  },
                },
                choice.text,
              );
            }),
          ),
        );
        if (!checked) {
          parts.push(
            h(
              'button.btn.primary.block',
              { disabled: picked.size === 0, onclick: () => render({ picked, checked: true }) },
              'Valider',
            ),
          );
        } else {
          parts.push(verdict(right), next(right));
        }
        break;
      }
      case 'cloze': {
        const sentence = clozeParts(quiz.cloze);
        const inputs = [];
        const checked = state.checked;
        const values = state.values ?? [];
        const line = h(
          'div.cloze',
          {},
          sentence.map((part) => {
            if (part.answer === undefined) return part.text;
            const index = inputs.length;
            const value = values[index] ?? '';
            const right = compareAnswer(value, part.answer) !== 'wrong';
            const input = h('input.blank' + (checked ? (right ? '.correct' : '.wrong') : ''), {
              // the right spelling, once checked
              value: checked ? part.answer : value,
              disabled: checked,
              size: Math.max(3, part.answer.length + 1),
              autocapitalize: 'off',
              autocomplete: 'off',
              spellcheck: false,
              onkeydown: (e) => {
                if (e.key === 'Enter') check();
              },
            });
            inputs.push(input);
            return input;
          }),
        );
        const check = (giveUp = false) =>
          render({ checked: true, values: inputs.map((input) => (giveUp ? '' : input.value)) });
        parts.push(line);
        if (!checked) {
          parts.push(
            h(
              'div.row',
              {},
              h('button.btn', { onclick: () => check(true) }, 'Je ne sais pas'),
              h('button.btn.primary', { onclick: () => check() }, 'Valider'),
            ),
          );
        } else {
          const answers = sentence.filter((part) => part.answer !== undefined);
          const results = answers.map((part, i) => compareAnswer(values[i] ?? '', part.answer));
          const right = results.every((result) => result !== 'wrong');
          const detail = !right
            ? 'Les bonnes réponses sont en vert.'
            : results.includes('close')
              ? "Attention à l'orthographe : elle est corrigée ci-dessus."
              : null;
          parts.push(verdict(right, detail), next(right));
        }
        setTimeout(() => !checked && inputs[0]?.focus(), 50);
        break;
      }
    }
    card.replaceChildren(...parts.filter(Boolean));
  };
  render();
  return card;
}

/**
 * Lets the user answer one question block, from its page.
 * `onGraded(quiz)` is called once it's answered, `onEdit()` to change it.
 */
export function answerQuiz(quiz, { onGraded, onEdit, readOnly = false }) {
  return sheet((close) => [
    answerCard(quiz, {
      onResult: (grade) => {
        if (!readOnly) {
          quiz.study = graded(quiz.study, grade);
          onGraded(quiz);
          toast(`À revoir dans ${describe(quiz.study.d - Date.now())}`);
        }
        close();
      },
    }),
    readOnly
      ? null
      : h('button.btn.ghost.block', { onclick: () => { close(); onEdit(); } }, icon('ballpoint'), 'Modifier la question'),
  ]);
}

// The note's quiz

/**
 * Shows every question block of `note`: how many there are and which are
 * due, to review them one after the other or go to one of them.
 */
export function noteQuiz(note, { name, onGraded, onGoTo, onAdd, onFlashcards, readOnly = false }) {
  const scrim = h('div.study.quiz-screen');
  const close = () => {
    scrim.classList.add('closing');
    setTimeout(() => scrim.remove(), 180);
    document.removeEventListener('keydown', onKey);
  };
  const onKey = (event) => {
    if (event.key === 'Escape') close();
  };
  document.addEventListener('keydown', onKey);

  let queue = null;
  let total = 0;
  let studied = 0;

  const start = (items) => {
    queue = [...items];
    total = queue.length;
    studied = 0;
    render();
  };

  const header = (title, progress = '') =>
    h(
      'div.study-header',
      {},
      h('button.icon-btn', { onclick: queue ? () => { queue = null; render(); } : close, 'aria-label': queue ? 'Retour' : 'Fermer' }, icon(queue ? 'back' : 'close')),
      h('strong', {}, title),
      h('span.progress', {}, progress),
    );

  function overview() {
    const all = note.quizzes;
    const due = all.filter(({ quiz }) => isDue(quiz.study));
    if (!all.length) {
      return h(
        'div.study-done',
        {},
        h('div.art', {}, icon('quiz')),
        h('h2', {}, 'Aucune question pour le moment'),
        h('p', {}, 'Ajoutez des questions sur vos pages de cours : elles se retrouvent toutes ici pour réviser.'),
        readOnly ? null : h('button.btn.primary', { onclick: () => { close(); onAdd(); } }, icon('plus'), 'Ajouter une question'),
        onFlashcards ? h('button.btn', { onclick: () => { close(); onFlashcards(); } }, 'Réviser les pages-fiches') : null,
      );
    }
    return h(
      'div.quiz-overview',
      {},
      h(
        'div.quiz-stats',
        {},
        h('div', {}, h('strong', {}, String(all.length)), h('span', {}, all.length > 1 ? 'questions' : 'question')),
        h('div', {}, h('strong', {}, String(due.length)), h('span', {}, 'à revoir')),
      ),
      due.length
        ? h('button.btn.primary.block', { onclick: () => start(due) }, icon('sparkles'), `Réviser (${due.length})`)
        : h('p.hint.center', {}, 'Tout est révisé pour le moment.'),
      h('button.btn.block', { onclick: () => start(all) }, 'Tout réviser'),
      onFlashcards ? h('button.btn.ghost.block', { onclick: () => { close(); onFlashcards(); } }, 'Réviser les pages-fiches') : null,
      h('div.sheet-label', {}, 'Les questions du carnet'),
      h(
        'div.quiz-list',
        {},
        all.map(({ page, quiz }) => {
          const index = note.pages.indexOf(page);
          const text = quiz.type === 'cloze' ? quiz.cloze.replace(/\[([^\]]*)\]/g, '…') : quiz.question.text || 'Question écrite à la main';
          const when = isDue(quiz.study) ? 'à revoir' : `dans ${describe(quiz.study.d - Date.now())}`;
          return h(
            'button.quiz-row',
            { onclick: () => { close(); onGoTo(page, quiz); } },
            h('span.kind', {}, QUIZ_LABELS[quiz.type]),
            h('span.text', {}, text),
            h('span.meta', {}, `p. ${index + 1} · ${when}`),
          );
        }),
      ),
      readOnly ? null : h('button.btn.ghost.block', { onclick: () => { close(); onAdd(); } }, icon('plus'), 'Ajouter une question'),
    );
  }

  function render() {
    if (!queue) {
      scrim.replaceChildren(header(`Quiz · ${name}`), overview());
      return;
    }
    if (!queue.length) {
      scrim.replaceChildren(
        header('Quiz'),
        h(
          'div.study-done',
          {},
          h('div.art', {}, icon('check')),
          h('h2', {}, 'Terminé !'),
          h('p', {}, `Questions révisées : ${studied}`),
          h('button.btn.primary', { onclick: () => { queue = null; render(); } }, 'Retour au quiz'),
          h('button.btn.ghost', { onclick: close }, 'Fermer'),
        ),
      );
      return;
    }
    const { quiz } = queue[0];
    scrim.replaceChildren(
      header('Quiz', `${studied} / ${total}`),
      h(
        'div.study-card',
        {},
        answerCard(quiz, {
          onResult: (grade) => {
            const item = queue.shift();
            if (!readOnly) {
              quiz.study = graded(quiz.study, grade);
              onGraded(quiz);
            }
            if (grade === 'again') queue.push(item);
            else studied++;
            render();
          },
        }),
      ),
    );
  }

  render();
  document.body.append(scrim);
  return close;
}
