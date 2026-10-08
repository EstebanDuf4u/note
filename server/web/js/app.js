// Note+ in the browser: the sign in page, the library and the editor,
// with the browser's back button going from a note to the library.

import { Api } from './api.js';
import { Editor } from './editor.js';
import { errorMessage, renderLibrary, renderSignIn } from './library.js';
import { toast } from './ui.js';

const root = document.getElementById('app');
let cleanup = null;

function teardown() {
  cleanup?.();
  cleanup = null;
}

function showSignIn(reason) {
  teardown();
  renderSignIn(root, {
    reason,
    onSignedIn: () => route(),
  });
}

function showLibrary() {
  teardown();
  if (location.pathname !== '/') history.replaceState(null, '', '/');
  const stop = renderLibrary(root, {
    onOpen: (note) => {
      history.pushState({ note }, '', urlOf(note));
      showNote(note);
    },
    onSignedOut: () => showSignIn(),
  });
  cleanup = stop;
}

function showNote(note) {
  teardown();
  const editor = new Editor(root, {
    path: note.path,
    name: note.name,
    share: note.token,
    create: note.create,
    paper: note.paper,
    onClose: () => {
      cleanup = null;
      if (history.state?.note) history.back();
      else showLibrary();
    },
  });
  cleanup = () => editor.destroy();
  // for testing from the browser's console
  window.noteplusEditor = editor;
}

/** Opens the note of a shared link, which adds it to the user's notes. */
async function openLink(token) {
  try {
    const shared = await Api.acceptShare(token);
    const name = shared.path.slice(shared.path.lastIndexOf('/') + 1);
    const note = shared.own
      ? { path: shared.path, name }
      : { path: shared.path, name, token, owner: shared.owner };
    history.replaceState(null, '', '/');
    history.pushState({ note }, '', urlOf(note));
    showNote(note);
    if (!shared.own) toast(`Carnet partagé par ${shared.owner}`);
  } catch (e) {
    toast(errorMessage(e));
    showLibrary();
  }
}

/** The address of a note, which opens it again after reloading the page. */
function urlOf(note) {
  return '/n' + encodeURI(note.path) + (note.token ? '?s=' + encodeURIComponent(note.token) : '');
}

function route() {
  const path = location.pathname;
  if (!Api.isSignedIn) {
    // a shared link is opened once signed in
    if (path.startsWith('/s/')) sessionStorage.setItem('noteplus.link', path.slice(3));
    return showSignIn(path.startsWith('/s/') ? 'Connectez-vous pour ouvrir le carnet partagé.' : undefined);
  }
  const link = path.startsWith('/s/') ? path.slice(3) : sessionStorage.getItem('noteplus.link');
  if (link) {
    sessionStorage.removeItem('noteplus.link');
    return openLink(decodeURIComponent(link));
  }
  if (path.startsWith('/n/') && history.state?.note) return showNote(history.state.note);
  if (path.startsWith('/n/')) {
    const notePath = decodeURI(path.slice(2));
    const token = new URLSearchParams(location.search).get('s') ?? undefined;
    return showNote({ path: notePath, name: notePath.slice(notePath.lastIndexOf('/') + 1), token });
  }
  showLibrary();
}

window.addEventListener('popstate', () => route());
route();
