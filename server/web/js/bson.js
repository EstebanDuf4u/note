// A small BSON codec for the messages that Note+ exchanges with its server.
//
// Numbers are written as doubles, which is what the app expects for sizes
// and coordinates, unless they're wrapped in `int()` for the values that the
// app reads as integers (colors, ids, counters).

/** Marks `value` to be written as an integer. */
export function int(value) {
  return new BsonInt(value);
}

export class BsonInt {
  constructor(value) {
    this.value = value;
  }
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

class Writer {
  constructor() {
    this.bytes = new Uint8Array(1024);
    this.view = new DataView(this.bytes.buffer);
    this.length = 0;
  }

  reserve(count) {
    if (this.length + count <= this.bytes.length) return;
    let size = this.bytes.length * 2;
    while (size < this.length + count) size *= 2;
    const bytes = new Uint8Array(size);
    bytes.set(this.bytes.subarray(0, this.length));
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer);
  }

  byte(value) {
    this.reserve(1);
    this.bytes[this.length++] = value;
  }

  int32(value) {
    this.reserve(4);
    this.view.setInt32(this.length, value, true);
    this.length += 4;
  }

  int64(value) {
    this.reserve(8);
    this.view.setBigInt64(this.length, BigInt(Math.trunc(value)), true);
    this.length += 8;
  }

  double(value) {
    this.reserve(8);
    this.view.setFloat64(this.length, value, true);
    this.length += 8;
  }

  raw(bytes) {
    this.reserve(bytes.length);
    this.bytes.set(bytes, this.length);
    this.length += bytes.length;
  }

  cstring(text) {
    this.raw(encoder.encode(text));
    this.byte(0);
  }

  document(object, isArray = false) {
    const start = this.length;
    this.int32(0); // the length, written once known
    const entries = isArray
      ? object.map((value, index) => [String(index), value])
      : Object.entries(object);
    for (const [key, value] of entries) {
      if (value === undefined) continue;
      this.element(key, value);
    }
    this.byte(0);
    this.view.setInt32(start, this.length - start, true);
  }

  element(key, value) {
    if (value === null) {
      this.byte(0x0a);
      this.cstring(key);
    } else if (value instanceof BsonInt) {
      const n = value.value;
      if (n >= -2147483648 && n <= 2147483647) {
        this.byte(0x10);
        this.cstring(key);
        this.int32(n);
      } else {
        this.byte(0x12);
        this.cstring(key);
        this.int64(n);
      }
    } else if (typeof value === 'number') {
      this.byte(0x01);
      this.cstring(key);
      this.double(value);
    } else if (typeof value === 'string') {
      this.byte(0x02);
      this.cstring(key);
      const bytes = encoder.encode(value);
      this.int32(bytes.length + 1);
      this.raw(bytes);
      this.byte(0);
    } else if (typeof value === 'boolean') {
      this.byte(0x08);
      this.cstring(key);
      this.byte(value ? 1 : 0);
    } else if (value instanceof Uint8Array) {
      this.byte(0x05);
      this.cstring(key);
      this.int32(value.length);
      this.byte(0); // generic binary
      this.raw(value);
    } else if (Array.isArray(value)) {
      this.byte(0x04);
      this.cstring(key);
      this.document(value, true);
    } else if (typeof value === 'object') {
      this.byte(0x03);
      this.cstring(key);
      this.document(value);
    } else {
      throw new Error(`Can't write ${typeof value} as bson`);
    }
  }
}

/** Returns the bson bytes of `object`. */
export function serialize(object) {
  const writer = new Writer();
  writer.document(object);
  return writer.bytes.slice(0, writer.length);
}

/** Returns the object in the bson `bytes`. */
export function deserialize(bytes) {
  if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;

  function cstring() {
    const end = bytes.indexOf(0, offset);
    const text = decoder.decode(bytes.subarray(offset, end));
    offset = end + 1;
    return text;
  }

  function document(isArray) {
    const length = view.getInt32(offset, true);
    const end = offset + length - 1;
    offset += 4;
    const result = isArray ? [] : {};
    while (offset < end) {
      const type = bytes[offset++];
      const key = cstring();
      const value = element(type);
      if (isArray) result.push(value);
      else result[key] = value;
    }
    offset = end + 1;
    return result;
  }

  function element(type) {
    switch (type) {
      case 0x01: {
        const value = view.getFloat64(offset, true);
        offset += 8;
        return value;
      }
      case 0x02: {
        const length = view.getInt32(offset, true);
        offset += 4;
        const text = decoder.decode(bytes.subarray(offset, offset + length - 1));
        offset += length;
        return text;
      }
      case 0x03:
        return document(false);
      case 0x04:
        return document(true);
      case 0x05: {
        const length = view.getInt32(offset, true);
        offset += 5; // the length and the subtype
        const value = bytes.slice(offset, offset + length);
        offset += length;
        return value;
      }
      case 0x07: // object id
        offset += 12;
        return null;
      case 0x08:
        return bytes[offset++] !== 0;
      case 0x09: {
        const value = new Date(Number(view.getBigInt64(offset, true)));
        offset += 8;
        return value;
      }
      case 0x0a:
        return null;
      case 0x10: {
        const value = view.getInt32(offset, true);
        offset += 4;
        return value;
      }
      case 0x11:
      case 0x12: {
        const value = Number(view.getBigInt64(offset, true));
        offset += 8;
        return value;
      }
      default:
        throw new Error(`Unknown bson type ${type}`);
    }
  }

  return document(false);
}
