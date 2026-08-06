#!/usr/bin/env node
// set-owner.mjs — repoint the site at a different GitHub owner.
//
// The site itself is base-path proof (every link is relative), so only the
// absolute URLs need rewriting: the canonical/OG meta tags, the "view source"
// links, and the docs. Run this once after forking or re-homing the repo:
//
//   node scripts/set-owner.mjs <new-owner> [repo-name]

import { readFile, writeFile, readdir } from "node:fs/promises";
import { dirname, join, resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";

const [owner, repo = "ai-news-digest"] = process.argv.slice(2);
if (!owner) {
  console.error("usage: node scripts/set-owner.mjs <new-owner> [repo-name]");
  process.exit(1);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const EXTS = new Set([".html", ".md", ".js", ".mjs", ".json"]);
const SKIP = new Set([".git", "node_modules", "data.json"]);

// Matches the previous owner/repo pair wherever it appears, in either the
// github.com path form or the *.github.io host form.
const PAIR = /([A-Za-z0-9_.-]+)(\.github\.io\/|\/)((?:ai-news-digest|[A-Za-z0-9_.-]*ai-news-digest))/g;

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (SKIP.has(entry.name)) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (EXTS.has(extname(entry.name))) yield full;
  }
}

let changed = 0;
for await (const file of walk(root)) {
  const before = await readFile(file, "utf8");
  const after = before.replace(PAIR, (m, _o, sep) =>
    sep === ".github.io/" ? `${owner}.github.io/${repo}` : `${owner}/${repo}`,
  );
  if (after !== before) {
    await writeFile(file, after);
    changed += 1;
    console.log(`updated ${file.slice(root.length + 1)}`);
  }
}

console.log(`\n${changed} file(s) updated → https://${owner}.github.io/${repo}/`);
