// The sign in page and the user's notebooks.

import { Api, ApiError } from './api.js';
import { confirm, h, icon, initials, prompt, sheet, toast } from './ui.js';

/** The colors of notebook covers, in the app's order. */
export const COVER_COLORS = [
  '#2f3e55', '#3b7dd8', '#2e9e8f', '#5ba84a', '#e2b33c',
  '#e5783b', '#d9485f', '#8e5bc7', '#7a6652', '#4a4a4a',
];

export const PAPERS = [
  { pattern: '', name: 'Blanc' },
  { pattern: 'lined', name: 'Ligné' },
  { pattern: 'grid', name: 'Quadrillé' },
  { pattern: 'dots', name: 'Pointillé' },
];

export function errorMessage(error) {
  const code = error instanceof ApiError ? error.code : 'unreachable';
  return (
    {
      unreachable: 'Impossible de joindre le serveur. Vérifiez votre connexion.',
      wrong_credentials: "Nom d'utilisateur ou mot de passe incorrect.",
      username_taken: "Ce nom d'utilisateur est déjà pris.",
      invalid_username: "Le nom d'utilisateur doit faire 3 à 32 lettres, chiffres, points ou tirets.",
      weak_password: 'Le mot de passe doit faire au moins 8 caractères.',
      too_many_attempts: 'Trop de tentatives. Réessayez dans quelques minutes.',
      registration_closed: "La création de comptes est fermée sur ce serveur.",
      not_found: "Ce lien ne fonctionne pas, ou n'est plus partagé.",
      unauthorized: 'Votre session a expiré. Reconnectez-vous.',
    }[code] ?? 'Une erreur est survenue. Réessayez.'
  );
}

export function renderSignIn(root, { onSignedIn, reason }) {
  const username = h('input', {
    autocomplete: 'username',
    autocapitalize: 'none',
    autocorrect: 'off',
    spellcheck: false,
    placeholder: "Nom d'utilisateur",
  });
  const password = h('input', {
    type: 'password',
    autocomplete: 'current-password',
    placeholder: 'Mot de passe',
  });
  const error = h('div.error', {}, reason ?? '');
  const signIn = h('button.btn.primary.block', { type: 'submit' }, 'Se connecter');
  const register = h('button.btn.ghost.block', { type: 'button' }, 'Créer un compte');

  async function submit(isRegistering) {
    error.textContent = '';
    if (!username.value.trim() || !password.value) {
      error.textContent = "Entrez votre nom d'utilisateur et votre mot de passe.";
      return;
    }
    signIn.disabled = register.disabled = true;
    try {
      await Api.signIn(username.value, password.value, isRegistering);
      onSignedIn();
    } catch (e) {
      error.textContent = errorMessage(e);
    } finally {
      signIn.disabled = register.disabled = false;
    }
  }

  register.onclick = () => submit(true);
  const form = h(
    'form.signin-card',
    {
      onsubmit: (event) => {
        event.preventDefault();
        submit(false);
      },
    },
    h('img.logo', { src: '/web/icons/icon-192.png', alt: '' }),
    h('h1', {}, 'Note+'),
    h('p', {}, 'Vos notes manuscrites, synchronisées en direct sur tous vos appareils.'),
    h('label.field', {}, icon('user'), username),
    h('label.field', {}, icon('lock'), password),
    error,
    signIn,
    register,
  );
  root.replaceChildren(h('div.signin', {}, form));

  // the server may not let new accounts be created
  Api.info()
    .then((info) => {
      if (info.registration === false) register.remove();
    })
    .catch(() => {});
}

function relativeName(path) {
  return path.slice(path.lastIndexOf('/') + 1);
}

function folderOf(path) {
  const index = path.lastIndexOf('/');
  return index > 0 ? path.slice(1, index) : '';
}

function coverOf(entry) {
  const index = entry?.c;
  return index !== undefined && index >= 0 ? COVER_COLORS[index] : null;
}

function notebookCard(note, { onOpen, onMenu, delay }) {
  const color = note.cover;
  const cover = h(
    'div.cover' + (color ? '' : '.paper'),
    { style: color ? { background: `linear-gradient(160deg, ${color}, ${shade(color)})` } : undefined },
    h('div.label', {}, note.name),
    note.shared ? h('div.badge', {}, icon('share')) : note.favorite ? h('div.badge', {}, icon('bookmark', { filled: true })) : null,
  );
  let pressTimer;
  const card = h(
    'button.notebook',
    {
      style: { animationDelay: `${delay}ms` },
      onclick: () => onOpen(note),
      oncontextmenu: (event) => {
        event.preventDefault();
        onMenu(note);
      },
      onpointerdown: () => {
        pressTimer = setTimeout(() => {
          pressTimer = null;
          onMenu(note);
        }, 550);
      },
      onpointerup: () => clearTimeout(pressTimer),
      onpointercancel: () => clearTimeout(pressTimer),
      onpointerleave: () => clearTimeout(pressTimer),
    },
    cover,
    h('div.name', {}, note.name),
    h('div.meta', {}, note.shared ? `Partagé par ${note.owner}` : note.folder || 'Carnet'),
  );
  // a long press opens the menu instead of the notebook
  card.addEventListener(
    'click',
    (event) => {
      if (pressTimer === null) {
        event.stopImmediatePropagation();
        pressTimer = undefined;
      }
    },
    true,
  );
  return card;
}

/** A darker shade of the hex `color`, for the cover's gradient. */
function shade(color) {
  const n = parseInt(color.slice(1), 16);
  const r = Math.round(((n >> 16) & 255) * 0.78);
  const g = Math.round(((n >> 8) & 255) * 0.78);
  const b = Math.round((n & 255) * 0.78);
  return `rgb(${r}, ${g}, ${b})`;
}

export function renderLibrary(root, { onOpen, onSignedOut }) {
  let tab = 'mine';
  let query = '';
  let notes = [];
  let shared = [];
  let loading = true;

  const search = h('input', {
    placeholder: 'Rechercher',
    type: 'search',
    oninput: () => {
      query = search.value.trim().toLowerCase();
      renderGrid();
    },
  });
  const tabs = h('div.segmented');
  const body = h('div.library-body');

  function renderTabs() {
    tabs.replaceChildren(
      ...[
        ['mine', 'Mes carnets'],
        ['shared', 'Partagés avec moi'],
      ].map(([value, label]) =>
        h(
          'button' + (tab === value ? '.selected' : ''),
          {
            onclick: () => {
              tab = value;
              renderTabs();
              renderGrid();
            },
          },
          label,
        ),
      ),
    );
  }

  function renderGrid() {
    const list = (tab === 'mine' ? notes : shared).filter(
      (note) => !query || note.name.toLowerCase().includes(query),
    );
    if (loading) {
      body.replaceChildren(h('div.empty', {}, h('div.spinner')));
      return;
    }
    if (!list.length) {
      body.replaceChildren(
        h(
          'div.empty',
          {},
          h('div.art', {}, icon(tab === 'mine' ? 'notebook' : 'share')),
          h('strong', {}, query ? 'Aucun résultat' : tab === 'mine' ? 'Aucun carnet' : 'Rien de partagé'),
          query
            ? `Aucun carnet ne correspond à « ${search.value} ».`
            : tab === 'mine'
              ? 'Créez votre premier carnet avec le bouton « Nouveau ».'
              : "Quand quelqu'un vous envoie un lien vers une note, ouvrez-le : elle apparaîtra ici.",
        ),
      );
      return;
    }
    body.replaceChildren(
      h(
        'div.grid',
        {},
        list.map((note, index) =>
          notebookCard(note, { onOpen, onMenu: showMenu, delay: Math.min(index, 12) * 30 }),
        ),
      ),
    );
  }

  async function load() {
    try {
      const [list, library] = await Promise.all([Api.notes(), Api.library().catch(() => ({ entries: {} }))]);
      const entries = library.entries ?? {};
      notes = list.notes
        .map((note) => ({
          path: note.path,
          name: relativeName(note.path),
          folder: folderOf(note.path),
          cover: coverOf(entries[note.path]),
          favorite: entries[note.path]?.f === true,
        }))
        .sort((a, b) => (b.favorite - a.favorite) || a.name.localeCompare(b.name, 'fr'));
      shared = (list.shared ?? []).map((note) => ({
        path: note.path,
        name: relativeName(note.path),
        owner: note.owner,
        token: note.token,
        shared: true,
      }));
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) return onSignedOut();
      toast(errorMessage(e));
    }
    loading = false;
    renderGrid();
  }

  async function showMenu(note) {
    const choice = await sheet((close) => [
      h('h2', {}, note.name),
      h(
        'div.menu',
        {},
        h('button', { onclick: () => close('open') }, icon('notebook'), 'Ouvrir'),
        note.shared
          ? h('button.danger', { onclick: () => close('leave') }, icon('logout'), 'Retirer de mes notes')
          : [
              h('button', { onclick: () => close('share') }, icon('link'), 'Copier le lien de partage'),
              h('button.danger', { onclick: () => close('delete') }, icon('trash'), 'Supprimer'),
            ],
      ),
    ]);
    if (choice === 'open') onOpen(note);
    if (choice === 'share') await copyShareLink(note.path);
    if (choice === 'delete') {
      const ok = await confirm({
        title: `Supprimer « ${note.name} » ?`,
        message: 'Le carnet sera supprimé sur tous vos appareils.',
        action: 'Supprimer',
        danger: true,
      });
      if (!ok) return;
      try {
        await Api.deleteNote(note.path);
        notes = notes.filter((n) => n !== note);
        renderGrid();
        toast('Carnet supprimé');
      } catch (e) {
        toast(errorMessage(e));
      }
    }
    if (choice === 'leave') {
      try {
        await Api.leaveShare(note.token);
        shared = shared.filter((n) => n !== note);
        renderGrid();
      } catch (e) {
        toast(errorMessage(e));
      }
    }
  }

  async function create() {
    let paper = PAPERS[1].pattern;
    const result = await sheet((close) => {
      const name = h('input', { placeholder: 'Nom du carnet', enterKeyHint: 'done' });
      const papers = h('div.papers');
      const renderPapers = () =>
        papers.replaceChildren(
          ...PAPERS.map((p) =>
            h(
              'button.paper-choice' + (p.pattern === paper ? '.selected' : ''),
              {
                onclick: () => {
                  paper = p.pattern;
                  renderPapers();
                },
              },
              h('div.swatch' + (p.pattern ? '.paper-' + p.pattern : '')),
              p.name,
            ),
          ),
        );
      renderPapers();
      const submit = () => {
        const value = name.value.trim().replaceAll('/', '-');
        if (!value) return name.focus();
        close({ name: value, paper });
      };
      name.addEventListener('keydown', (event) => event.key === 'Enter' && submit());
      return [
        h('h2', {}, 'Nouveau carnet'),
        h('div.stack', {}, h('div.field', {}, icon('notebook'), name), papers),
        h(
          'div.row',
          { style: { marginTop: '18px' } },
          h('button.btn', { onclick: () => close() }, 'Annuler'),
          h('button.btn.primary', { onclick: submit }, 'Créer'),
        ),
      ];
    });
    if (!result) return;
    let path = '/' + result.name;
    for (let i = 2; notes.some((n) => n.path === path); i++) path = `/${result.name} ${i}`;
    onOpen({ path, name: relativeName(path), create: true, paper: result.paper });
  }

  async function showAccount() {
    const choice = await sheet((close) => [
      h(
        'div',
        { style: { display: 'flex', alignItems: 'center', gap: '14px', margin: '6px 0 18px' } },
        h('div.avatar', { style: { width: '48px', height: '48px', fontSize: '20px' } }, initials(Api.username)),
        h('div', {}, h('h2', { style: { margin: 0 } }, Api.username), h('div', { style: { color: 'var(--muted)' } }, location.host)),
      ),
      h(
        'div.menu',
        {},
        h('button', { onclick: () => close('install') }, icon('sparkles'), "Ajouter à l'écran d'accueil"),
        h('button.danger', { onclick: () => close('signout') }, icon('logout'), 'Se déconnecter'),
      ),
    ]);
    if (choice === 'signout') {
      await Api.signOut();
      onSignedOut();
    }
    if (choice === 'install') {
      await sheet((close) => [
        h('h2', {}, "Sur l'écran d'accueil"),
        h(
          'p',
          {},
          "Sur iPhone ou iPad, touchez le bouton Partager de Safari, puis « Sur l'écran d'accueil ». Note+ s'ouvrira alors en plein écran, comme une app.",
        ),
        h('button.btn.primary.block', { onclick: () => close() }, "J'ai compris"),
      ]);
    }
  }

  renderTabs();
  root.replaceChildren(
    h(
      'div.library',
      {},
      h(
        'div.library-header',
        {},
        h(
          'div.top',
          {},
          h('h1', {}, 'Carnets'),
          h('button.avatar', { onclick: showAccount, 'aria-label': 'Compte' }, initials(Api.username)),
        ),
        h('label.field', { style: { height: '44px' } }, icon('search'), search),
        tabs,
      ),
      body,
      h('button.fab', { onclick: create }, icon('plus'), 'Nouveau'),
    ),
  );
  renderGrid();
  load();
  const refresh = () => document.visibilityState === 'visible' && load();
  document.addEventListener('visibilitychange', refresh);
  return () => document.removeEventListener('visibilitychange', refresh);
}

/** Copies the link that lets others open the note at `path`. */
export async function copyShareLink(path) {
  try {
    const { token } = await Api.share(path);
    const link = `${location.origin}/s/${token}`;
    await sheet((close) => [
      h('h2', {}, 'Partager'),
      h(
        'p',
        {},
        'Toute personne qui a ce lien peut ouvrir ce carnet et y écrire avec vous, en direct. Il lui faut un compte sur ce serveur.',
      ),
      h(
        'div.link-box',
        {},
        h('span', {}, link),
        h(
          'button.btn.primary',
          {
            style: { height: '40px', padding: '0 14px' },
            onclick: async () => {
              try {
                if (navigator.share) await navigator.share({ url: link, title: 'Note+' });
                else await navigator.clipboard.writeText(link);
                toast('Lien prêt à être envoyé');
              } catch {
                // cancelled
              }
            },
          },
          icon('copy'),
          'Copier',
        ),
      ),
      h('div', { style: { height: '12px' } }),
      h(
        'button.btn.danger.block',
        {
          onclick: async () => {
            await Api.unshare(path);
            toast('Ce lien ne fonctionne plus');
            close();
          },
        },
        'Arrêter le partage',
      ),
    ]);
  } catch (e) {
    toast(errorMessage(e));
  }
}

export { prompt };
