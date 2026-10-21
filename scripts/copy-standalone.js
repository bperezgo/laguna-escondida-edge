// Copy a pnpm Next.js standalone tree into an all-real, portable folder.
// The .pnpm store's symlinks EPERM on realpath/stat on Windows and contain cycles, so links are
// resolved with readlink only and each directory is skipped if it is its own ancestor.
//
// Usage:  node copy-standalone.js <srcDir> <dstDir>

const fs = require('fs');
const path = require('path');

const [, , SRC, DST] = process.argv;
if (!SRC || !DST) { console.error('usage: node copy-standalone.js <src> <dst>'); process.exit(2); }

// Returns the first non-symlink path in the chain, or null if a link is dangling.
function resolveReal(p) {
  let cur = p;
  for (let i = 0; i < 40; i++) {
    let st;
    try { st = fs.lstatSync(cur); } catch { return null; }
    if (!st.isSymbolicLink()) return cur;
    let link;
    try { link = fs.readlinkSync(cur); } catch { return null; }
    cur = path.resolve(path.dirname(cur), link);
  }
  return null;
}

function walk(src, dst, ancestors) {
  const real = resolveReal(src);
  if (real === null) return;

  let st;
  try { st = fs.lstatSync(real); } catch { return; }

  if (st.isDirectory()) {
    const key = path.normalize(real).toLowerCase();
    if (ancestors.has(key)) return;
    const next = new Set(ancestors); next.add(key);
    fs.mkdirSync(dst, { recursive: true });
    let entries;
    try { entries = fs.readdirSync(real); } catch { return; }
    for (const e of entries) walk(path.join(real, e), path.join(dst, e), next);
  } else if (st.isFile()) {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(real, dst);
  }
}

walk(SRC, DST, new Set());
