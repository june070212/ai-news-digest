#!/usr/bin/env node
// build-digest.mjs — fetch the feeds and prerender the digest into
// assets/data.json.
//
// GitHub Pages serves static files only, so the digest can't be fetched in the
// browser (the feeds send no CORS headers, and we don't want a proxy). Instead
// the workflow runs this at build time and on a schedule, so the published
// JSON is always at most a few hours stale.

import { writeFile, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { collectDigest, FEEDS } from "./feeds.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = resolve(root, "assets/data.json");

const days = Number(process.env.DIGEST_DAYS || 14);
const limit = Number(process.env.DIGEST_LIMIT || 60);

const { stories, sources } = await collectDigest({ days, limit });

const healthy = sources.filter((s) => s.ok).length;
if (healthy === 0) {
  console.error("all feeds failed — refusing to publish an empty digest");
  for (const s of sources) console.error(`  ${s.id}: ${s.error}`);
  process.exit(1);
}

const counts = { high: 0, medium: 0, low: 0 };
const tags = new Map();
for (const s of stories) {
  counts[s.importance] = (counts[s.importance] ?? 0) + 1;
  for (const t of s.tags) tags.set(t, (tags.get(t) ?? 0) + 1);
}

const digest = {
  generatedAt: new Date().toISOString(),
  window: { days, limit },
  totals: {
    stories: stories.length,
    github: stories.filter((s) => s.org === "GitHub").length,
    microsoft: stories.filter((s) => s.org !== "GitHub").length,
    ...counts,
  },
  tags: [...tags.entries()].sort((a, b) => b[1] - a[1]).map(([tag, count]) => ({ tag, count })),
  sources: sources.map(({ id, label, org, ok, count, error }) => ({ id, label, org, ok, count, error })),
  stories,
};

await mkdir(dirname(out), { recursive: true });
await writeFile(out, `${JSON.stringify(digest, null, 2)}\n`);

console.log(
  `wrote ${out}\n  ${stories.length} stories (${counts.high} high / ${counts.medium} medium / ${counts.low} low)` +
    `\n  ${healthy}/${FEEDS.length} feeds healthy`,
);
