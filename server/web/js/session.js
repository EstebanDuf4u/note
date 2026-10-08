// Keeps a note in sync with the other devices that have it open, through
// the Note+ server. This follows `realtime_session.dart` in the app, without
// the text merging, since text isn't edited here.

import { deserialize, int, serialize } from './bson.js';
import { newOpId } from './model.js';

export class Session {
  /**
   * @param {object} options
   * @param {string} options.url the server's websocket url
   * @param {string} options.token the session token of the signed in user
   * @param {string} options.room the path of the note in the user's library
   * @param {string} [options.share] the token of the link of another
   *   account's note, which is then opened instead of `room`
   * @param {string} options.clientId identifies this browser
   * @param {boolean} [options.create] whether this is a new note
   */
  constructor({ url, token, room, share, clientId, create = false }) {
    Object.assign(this, { url, token, room, share, clientId, create });
    this.seq = 0;
    /** The operations sent but not acknowledged yet, by their id. */
    this.pending = new Map();
    this.state = 'offline'; // or 'catchingUp', 'live'
    this.stopped = null; // why it gave up: 'deleted' or 'unauthorized'
    this.reconnectDelay = 1000;
    this.listeners = {};
  }

  /** Calls `listener` on `event`: op, state, presence, stopped, synced. */
  on(event, listener) {
    (this.listeners[event] ??= []).push(listener);
    return this;
  }

  emit(event, ...args) {
    for (const listener of this.listeners[event] ?? []) listener(...args);
  }

  setState(state) {
    if (this.state === state) return;
    this.state = state;
    this.emit('state', state);
  }

  start() {
    if (this.closed || this.stopped) return;
    const socket = new WebSocket(this.url);
    socket.binaryType = 'arraybuffer';
    this.socket = socket;
    socket.onopen = () => {
      this.setState('catchingUp');
      this.send({
        k: 'join',
        room: this.room,
        since: int(this.seq),
        client: this.clientId,
        token: this.token,
        create: this.create && this.seq === 0,
        share: this.share ?? undefined,
      });
    };
    socket.onmessage = (event) => this.onMessage(event.data);
    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.setState('offline');
      if (this.closed || this.stopped) return;
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = setTimeout(() => this.start(), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
    };
    socket.onerror = () => socket.close();
  }

  send(message) {
    if (this.socket?.readyState !== WebSocket.OPEN) return false;
    this.socket.send(serialize(message));
    return true;
  }

  onMessage(data) {
    let message;
    try {
      message = deserialize(new Uint8Array(data));
    } catch (e) {
      console.error('Bad message', e);
      return;
    }
    switch (message.k) {
      case 'op': {
        const seq = message.seq;
        if (message.from === this.clientId && this.pending.has(message.cid)) {
          // ours, which the server got before we lost its ack
          this.pending.delete(message.cid);
        } else {
          this.emit('op', message.d, seq);
        }
        if (seq > this.seq) this.seq = seq;
        break;
      }
      case 'ack':
        this.pending.delete(message.cid);
        if (message.seq > this.seq) this.seq = message.seq;
        this.emit('ack');
        break;
      case 'synced':
        if (message.head > this.seq) this.seq = message.head;
        this.setState('live');
        this.reconnectDelay = 1000;
        for (const [cid, op] of this.pending) {
          this.send({ k: 'op', cid: int(cid), d: op });
        }
        this.emit('synced');
        break;
      case 'presence':
        this.emit('presence', message.from, message.user, message.d);
        break;
      case 'deleted':
        this.stop('deleted');
        break;
      case 'error':
        console.error('Server error', message.message);
        if (message.code === 'auth') this.stop('unauthorized');
        break;
    }
  }

  /** Sends `ops` now, or once reconnected. */
  submit(ops) {
    for (const op of ops) {
      const cid = newOpId();
      this.pending.set(cid, op);
      if (this.state === 'live') this.send({ k: 'op', cid: int(cid), d: op });
    }
  }

  /** Tells the others where this user is, or that they left if null. */
  sendPresence(presence) {
    if (this.state === 'live') this.send({ k: 'presence', d: presence });
  }

  get hasPending() {
    return this.pending.size > 0;
  }

  stop(reason) {
    if (this.stopped) return;
    this.stopped = reason;
    this.socket?.close();
    this.setState('offline');
    this.emit('stopped', reason);
  }

  close() {
    this.sendPresence(null);
    this.closed = true;
    clearTimeout(this.reconnectTimer);
    this.socket?.close();
  }
}
