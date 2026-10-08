// Just enough of Quill's Delta format to follow the text of a page:
// composing a change into a document.

function opLength(op) {
  if (typeof op.delete === 'number') return op.delete;
  if (typeof op.retain === 'number') return op.retain;
  return typeof op.insert === 'string' ? op.insert.length : 1;
}

class Iterator {
  constructor(ops) {
    this.ops = ops;
    this.index = 0;
    this.offset = 0;
  }

  hasNext() {
    return this.peekLength() < Infinity;
  }

  peekLength() {
    const op = this.ops[this.index];
    return op ? opLength(op) - this.offset : Infinity;
  }

  peekType() {
    const op = this.ops[this.index];
    if (!op) return 'retain';
    if (typeof op.delete === 'number') return 'delete';
    if (typeof op.retain === 'number') return 'retain';
    return 'insert';
  }

  next(length = Infinity) {
    const op = this.ops[this.index];
    if (!op) return { retain: Infinity };
    const offset = this.offset;
    const opLen = opLength(op);
    if (length >= opLen - offset) {
      length = opLen - offset;
      this.index++;
      this.offset = 0;
    } else {
      this.offset += length;
    }
    if (typeof op.delete === 'number') return { delete: length };
    const result = {};
    if (op.attributes) result.attributes = op.attributes;
    if (typeof op.retain === 'number') result.retain = length;
    else if (typeof op.insert === 'string')
      result.insert = op.insert.substr(offset, length);
    else result.insert = op.insert;
    return result;
  }
}

function push(ops, op) {
  const last = ops[ops.length - 1];
  const sameAttributes =
    JSON.stringify(last?.attributes ?? null) ===
    JSON.stringify(op.attributes ?? null);
  if (last && sameAttributes) {
    if (typeof op.insert === 'string' && typeof last.insert === 'string') {
      last.insert += op.insert;
      return;
    }
    if (typeof op.retain === 'number' && typeof last.retain === 'number') {
      last.retain += op.retain;
      return;
    }
  }
  if (last && typeof op.delete === 'number' && typeof last.delete === 'number') {
    last.delete += op.delete;
    return;
  }
  ops.push({ ...op });
}

function composeAttributes(a = {}, b = {}, keepNull) {
  const result = { ...a, ...b };
  if (!keepNull) {
    for (const key of Object.keys(result)) {
      if (result[key] === null) delete result[key];
    }
  }
  return Object.keys(result).length ? result : undefined;
}

/** Returns `document` with `change` applied to it. */
export function compose(document, change) {
  const a = new Iterator(document);
  const b = new Iterator(change);
  const ops = [];
  while (a.hasNext() || b.hasNext()) {
    if (b.peekType() === 'insert') {
      push(ops, b.next());
    } else if (a.peekType() === 'delete') {
      push(ops, a.next());
    } else {
      const length = Math.min(a.peekLength(), b.peekLength());
      const thisOp = a.next(length);
      const otherOp = b.next(length);
      if (typeof otherOp.retain === 'number') {
        const op = {};
        if (typeof thisOp.retain === 'number') op.retain = length;
        else op.insert = thisOp.insert;
        const attributes = composeAttributes(
          thisOp.attributes,
          otherOp.attributes,
          typeof thisOp.retain === 'number',
        );
        if (attributes) op.attributes = attributes;
        push(ops, op);
      } else if (
        typeof otherOp.delete === 'number' &&
        typeof thisOp.retain === 'number'
      ) {
        push(ops, otherOp);
      }
    }
  }
  // a trailing retain changes nothing
  const last = ops[ops.length - 1];
  if (last && typeof last.retain === 'number' && !last.attributes) ops.pop();
  return ops;
}

/** The plain text of `document`, one entry per line with its attributes. */
export function lines(document) {
  const result = [];
  let current = { spans: [], attributes: {} };
  for (const op of document) {
    if (typeof op.insert !== 'string') continue;
    const parts = op.insert.split('\n');
    parts.forEach((part, index) => {
      if (part) current.spans.push({ text: part, attributes: op.attributes ?? {} });
      if (index < parts.length - 1) {
        current.attributes = op.attributes ?? {};
        result.push(current);
        current = { spans: [], attributes: {} };
      }
    });
  }
  if (current.spans.length) result.push(current);
  return result;
}

export function isEmpty(document) {
  return !document.some(
    (op) => typeof op.insert !== 'string' || op.insert.trim().length,
  );
}
