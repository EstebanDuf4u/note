// Writes test/fixtures/web_ops.bson: operations as the web editor writes
// them, which test/web_interop_test.dart checks that the app understands.
// Run from the repository's root: node server/web/test/make_fixture.mjs
import { writeFileSync } from 'node:fs';
import { serialize } from '../js/bson.js';
import { Note, Ops, Stroke } from '../js/model.js';
import { base64Url, sha256 } from '../js/sha256.js';
import { graded } from '../js/study.js';

const note = new Note();
const page = note.pages[0];
const options = { s: 50, t: 0.5, sm: 0, sl: 0.5, sp: false, cs: true, ce: true, f: true };
const highlighter = new Stroke({
  id: 'webStroke1', tool: 'Highlighter', pressureEnabled: false, color: 0x64ffeb3b,
  points: [[100, 100], [200, 150]], options,
});
const pen = new Stroke({
  id: 'webStroke2', points: [[10, 20, 0.25], [30, 40, 0.75]], options: { ...options, s: 5 },
});
const circle = new Stroke({
  id: 'webCircle', tool: 'ShapePen', pressureEnabled: false, shape: 'circle',
  cx: 500, cy: 600, r: 80, options: { ...options, s: 4 },
});
page.bookmark = 'Web';

// a 1x1 png
const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='), (c) => c.charCodeAt(0));
const image = {
  uid: 'webImage1', extension: '.png', hash: base64Url(sha256(png)), bytes: png,
  x: 100, y: 200, w: 300, h: 150, invertible: false, fit: 1,
};
page.study = graded(null, 'good', Date.UTC(2026, 9, 8));

const ops = [
  Ops.addStroke(page, highlighter),
  Ops.addStroke(page, pen),
  Ops.addStroke(page, circle),
  Ops.scaleStrokes([pen], 10, 20, 2),
  Ops.bookmark(page),
  ...Ops.addImage(page, image),
  Ops.updateImage(page, { ...image, x: 120 }),
  Ops.flashcards(true),
  Ops.study(page),
];
writeFileSync('test/fixtures/web_ops.bson', serialize({ ops }));
