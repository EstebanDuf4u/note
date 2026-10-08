// The http requests to the Note+ server that the web editor is served by.

const TOKEN_KEY = 'noteplus.token';
const USER_KEY = 'noteplus.user';
const CLIENT_KEY = 'noteplus.client';

export class ApiError extends Error {
  constructor(code, status) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function storage(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // private browsing: the session only lasts until the page is closed
  }
  return null;
}

let memoryToken = null;

export const Api = {
  get token() {
    return memoryToken ?? storage(TOKEN_KEY);
  },

  get username() {
    return storage(USER_KEY) ?? '';
  },

  get isSignedIn() {
    return !!this.token;
  },

  /** Identifies this browser among the account's devices. */
  get clientId() {
    let id = storage(CLIENT_KEY);
    if (!id) {
      id = 'web-' + crypto.getRandomValues(new Uint32Array(2)).join('');
      storage(CLIENT_KEY, id);
    }
    return id;
  },

  get webSocketUrl() {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${protocol}//${location.host}/`;
  },

  async request(method, path, body) {
    let response;
    try {
      response = await fetch(path, {
        method,
        headers: {
          Accept: 'application/json',
          ...(body ? { 'Content-Type': 'application/json' } : {}),
          ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch {
      throw new ApiError('unreachable', 0);
    }
    let json = {};
    try {
      json = await response.json();
    } catch {
      // not json
    }
    if (!response.ok) {
      if (response.status === 401) this.forget();
      throw new ApiError(json.error ?? 'server_error', response.status);
    }
    return json;
  },

  async signIn(username, password, register) {
    const json = await this.request('POST', register ? '/register' : '/login', {
      username: username.trim(),
      password,
    });
    memoryToken = json.token;
    storage(TOKEN_KEY, json.token);
    storage(USER_KEY, json.username);
    return json.username;
  },

  async signOut() {
    try {
      await this.request('POST', '/logout');
    } catch {
      // the session stays valid on the server, but we forget it
    }
    this.forget();
  },

  forget() {
    memoryToken = null;
    storage(TOKEN_KEY, null);
  },

  info: () => Api.request('GET', '/'),
  notes: () => Api.request('GET', '/notes'),
  library: (entries) =>
    entries ? Api.request('POST', '/library', { entries }) : Api.request('GET', '/library'),
  deleteNote: (path) => Api.request('POST', '/notes/delete', { path }),
  share: (path) => Api.request('POST', '/notes/share', { path }),
  unshare: (path) => Api.request('POST', '/notes/unshare', { path }),
  acceptShare: (token) => Api.request('POST', '/shares/accept', { token }),
  leaveShare: (token) => Api.request('POST', '/shares/leave', { token }),
};
