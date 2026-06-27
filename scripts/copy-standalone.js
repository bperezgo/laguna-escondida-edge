// copy-standalone.js — copy a Next.js standalone tree into a portable, self-contained folder.
//
// Why this exists: with pnpm, .next/standalone/node_modules is a web of symlinks into the
// build repo's .pnpm store. Copying it portably on Windows is the hard part:
//   - PowerShell Copy-Item throws "Access denied" traversing the store's reparse points.
//   - Preserving symlinks verbatim leaves links Windows/Node can't stat at runtime (EPERM).
//   - fs.cpSync({dereference:true}) follows a symlink CYCLE in the store and stack-overflows.
//   - fs.realpathSync / statSync (which FOLLOW links) throw EPERM on these links even with
//     Developer Mode on — so we must NOT follow links via the OS resolver.
//
// Approach: walk manually. Resolve each symlink ONLY with fs.readlinkSync (reads the target
// string without following — no EPERM) and recurse into the resolved path. Copy REAL files and
// directories, with ancestor-based cycle detection (skip a dir only if it is its own ancestor
// on the current path). Result: an all-real tree (no reparse points) that runs anywhere.
//
// Usage:  node copy-standalone.js <srcDir> <dstDir>

const fs = require('fs');
const path = require('path');

const [, , SRC, DST] = process.argv;
if (!SRC || !DST) { console.error('usage: node copy-standalone.js <src> <dst>'); process.exit(2); }

// Follow a symlink chain using readlink only (never realpath/stat, which EPERM on Windows here).
// Returns the first non-symlink path, or null if a link is dangling/unreadable.
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
  return null; // too many hops — treat as unresolved
}

function walk(src, dst, ancestors) {
  const real = resolveReal(src);
  if (real === null) return;

  let st;
  try { st = fs.lstatSync(real); } catch { return; } // real is non-symlink, so lstat == stat

  if (st.isDirectory()) {
    const key = path.normalize(real).toLowerCase();
    if (ancestors.has(key)) return;              // true cycle on this path -> stop
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
