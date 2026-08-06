// feeds.mjs — RSS/Atom retrieval + curation.
//
// Dependency-free: fetching goes through safeFetch (allow-listed hosts + hard
// timeout), parsing is a small tolerant regex reader for RSS 2.0 and Atom.
// Everything here returns plain data; the HTTP layer owns caching.

import { safeFetch } from "./net.mjs";

// Curated, GitHub + Microsoft Developer first — the same shape of source list the
// reference digest uses. `weight` nudges importance scoring toward the feeds a
// developer audience cares most about.
export const FEEDS = [
  { id: "github-changelog", label: "GitHub Changelog", org: "GitHub", url: "https://github.blog/changelog/feed/", weight: 3 },
  { id: "github-blog", label: "GitHub Blog", org: "GitHub", url: "https://github.blog/feed/", weight: 2 },
  { id: "ms-devblogs", label: "Microsoft DevBlogs", org: "Microsoft", url: "https://devblogs.microsoft.com/feed/", weight: 2 },
  { id: "ms-dotnet", label: ".NET Blog", org: "Microsoft", url: "https://devblogs.microsoft.com/dotnet/feed/", weight: 1 },
  { id: "ms-changelog", label: "Microsoft Developer Changelog", org: "Microsoft", url: "https://developer.microsoft.com/api/changelog/rss", weight: 2 },
  { id: "azure-blog", label: "Azure Blog", org: "Microsoft", url: "https://azure.microsoft.com/en-us/blog/feed/", weight: 1 },
];

export const FEEDS_BY_ID = new Map(FEEDS.map((f) => [f.id, f]));

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", "#39": "'", nbsp: " ", "#8217": "\u2019", "#8216": "\u2018", "#8220": "\u201c", "#8221": "\u201d", "#8211": "\u2013", "#8212": "\u2014", "#8230": "\u2026" };

function decodeEntities(text) {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (whole, name) => {
    if (Object.prototype.hasOwnProperty.call(ENTITIES, name)) return ENTITIES[name];
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole;
    }
    return whole;
  });
}

function stripHtml(text) {
  return decodeEntities(
    String(text)
      .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
      .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<[^>]*>/g, " ")
  )
    .replace(/\s+/g, " ")
    .trim();
}

function tagText(block, tag) {
  const m = block.match(new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`, "i"));
  return m ? stripHtml(m[1]) : "";
}

function linkOf(block) {
  const rss = tagText(block, "link");
  if (rss && /^https?:/i.test(rss)) return rss;
  const atom = block.match(/<link[^>]*rel=["']alternate["'][^>]*href=["']([^"']+)["']/i)
    || block.match(/<link[^>]*href=["']([^"']+)["']/i);
  return atom ? decodeEntities(atom[1]) : "";
}

function categoriesOf(block) {
  const out = [];
  const rss = block.matchAll(/<category(?:\s[^>]*)?>([\s\S]*?)<\/category>/gi);
  for (const m of rss) out.push(stripHtml(m[1]));
  const atom = block.matchAll(/<category[^>]*term=["']([^"']+)["'][^>]*\/?>/gi);
  for (const m of atom) out.push(decodeEntities(m[1]));
  return out.filter(Boolean);
}

// Tolerant RSS 2.0 + Atom reader. Returns raw entries; scoring happens later.
export function parseFeed(xml) {
  const blocks = [
    ...String(xml).matchAll(/<item(?:\s[^>]*)?>([\s\S]*?)<\/item>/gi),
    ...String(xml).matchAll(/<entry(?:\s[^>]*)?>([\s\S]*?)<\/entry>/gi),
  ];
  const entries = [];
  for (const [, block] of blocks) {
    const title = tagText(block, "title");
    const url = linkOf(block);
    if (!title || !url) continue;
    const published =
      tagText(block, "pubDate") || tagText(block, "published") || tagText(block, "updated") || tagText(block, "dc:date");
    const parsed = published ? new Date(published) : null;
    entries.push({
      title,
      url,
      published: parsed && !Number.isNaN(parsed.getTime()) ? parsed.toISOString() : null,
      summary:
        tagText(block, "description") ||
        tagText(block, "summary") ||
        tagText(block, "content:encoded") ||
        tagText(block, "content"),
      categories: categoriesOf(block),
    });
  }
  return entries;
}

const AI_TERMS = [
  "copilot", "ai ", " ai", "agent", "agentic", "llm", "model", "gpt", "openai", "claude",
  "gemini", "foundry", "mcp", "machine learning", "inference", "prompt", "rag", "semantic kernel",
];
const SHIP_TERMS = ["general availability", "generally available", " ga ", "now available", "public preview", "launch", "release", "ship", "announcing", "introducing"];
const BREAK_TERMS = ["breaking change", "deprecat", "retire", "end of support", "sunset", "removal", "security", "vulnerabilit", "cve-"];

const TAG_RULES = [
  ["Copilot", ["copilot"]],
  ["Agents", ["agent", "agentic", "mcp"]],
  ["AI", AI_TERMS],
  ["Actions", ["actions", "workflow", "ci/cd", "runner"]],
  ["Security", ["security", "vulnerabilit", "cve-", "secret scanning", "dependabot", "advisor"]],
  ["Azure", ["azure"]],
  [".NET", [".net", "c#", "aspnet", "asp.net", "blazor"]],
  ["VS Code", ["vs code", "visual studio code", "vscode"]],
  ["Visual Studio", ["visual studio 20", "visual studio 1"]],
  ["API", ["api", "graphql", "rest", "sdk", "cli"]],
  ["Deprecation", ["deprecat", "retire", "end of support", "sunset", "breaking change"]],
  ["Preview", ["public preview", "private preview", "beta", "experimental"]],
  ["GA", ["general availability", "generally available", "now available"]],
];

const hits = (haystack, terms) => terms.reduce((n, term) => (haystack.includes(term) ? n + 1 : n), 0);

function tagsFor(haystack, categories) {
  const tags = new Set();
  for (const [tag, terms] of TAG_RULES) if (hits(haystack, terms)) tags.add(tag);
  for (const c of categories.slice(0, 3)) {
    const clean = c.trim();
    if (clean && clean.length <= 22 && !/^\d+$/.test(clean)) tags.add(clean);
  }
  return [...tags].slice(0, 5);
}

const ageDays = (iso, now) => (iso ? (now - new Date(iso).getTime()) / 86400000 : 30);

// Deterministic relevance score → Low / Medium / High importance, mirroring the
// reference digest's "developer impact" ranking. No AI needed for the ranking.
function scoreOf(entry, feed, now) {
  const haystack = `${entry.title} ${entry.summary} ${entry.categories.join(" ")}`.toLowerCase();
  let score = feed.weight * 6;
  score += Math.min(hits(haystack, AI_TERMS), 4) * 7;
  score += Math.min(hits(haystack, SHIP_TERMS), 3) * 5;
  score += Math.min(hits(haystack, BREAK_TERMS), 3) * 6;
  if (haystack.includes("copilot")) score += 10;
  const age = ageDays(entry.published, now);
  score += age <= 1 ? 16 : age <= 3 ? 11 : age <= 7 ? 6 : age <= 14 ? 2 : 0;
  return Math.round(score);
}

const importanceOf = (score) => (score >= 62 ? "high" : score >= 45 ? "medium" : "low");

// Same story republished by several Microsoft feeds → keep the highest-weight copy.
function hostOf(url) {
  try { return new URL(url).hostname.toLowerCase(); } catch { return ""; }
}

const dedupeKey = (entry) => {
  const path = (() => {
    try { return new URL(entry.url).pathname.replace(/\/+$/, "").toLowerCase(); } catch { return entry.url.toLowerCase(); }
  })();
  const title = entry.title.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return `${title}|${path.split("/").pop()}`;
};

async function fetchFeed(feed) {
  const res = await safeFetch(feed.url, {
    headers: { Accept: "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8", "User-Agent": "copilot-canvas-ai-news-digest" },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return parseFeed(await res.text());
}

/**
 * Fetch every enabled feed, curate, dedupe and rank.
 * Returns { stories, sources } — sources carry per-feed status for the UI.
 */
export async function collectDigest({ feedIds, days = 14, limit = 40 } = {}) {
  const wanted = FEEDS.filter((f) => !feedIds?.length || feedIds.includes(f.id));
  const now = Date.now();
  const cutoff = now - days * 86400000;

  const settled = await Promise.allSettled(wanted.map((f) => fetchFeed(f)));
  const sources = [];
  const best = new Map();

  settled.forEach((result, i) => {
    const feed = wanted[i];
    if (result.status !== "fulfilled") {
      sources.push({ ...feed, ok: false, count: 0, error: String(result.reason?.message ?? result.reason) });
      return;
    }
    let kept = 0;
    for (const entry of result.value) {
      if (entry.published && new Date(entry.published).getTime() < cutoff) continue;
      const score = scoreOf(entry, feed, now);
      const story = {
        id: `${feed.id}:${dedupeKey(entry)}`.slice(0, 160),
        title: entry.title,
        url: entry.url,
        summary: entry.summary.slice(0, 320),
        published: entry.published,
        sourceId: feed.id,
        source: feed.label,
        // Attribute by the destination host, not the feed: the Microsoft
        // Developer changelog republishes GitHub stories.
        org: /(^|\.)github\.(com|blog|blog\.com)$/i.test(hostOf(entry.url)) ? "GitHub" : feed.org,
        score,
        importance: importanceOf(score),
        tags: tagsFor(`${entry.title} ${entry.summary}`.toLowerCase(), entry.categories),
      };
      const key = dedupeKey(entry);
      const existing = best.get(key);
      if (!existing || existing.score < story.score) best.set(key, story);
      kept += 1;
    }
    sources.push({ ...feed, ok: true, count: kept, error: null });
  });

  const stories = [...best.values()]
    .sort((a, b) => b.score - a.score || String(b.published).localeCompare(String(a.published)))
    .slice(0, limit)
    .map((s, i) => ({ ...s, rank: i + 1 }));

  return { stories, sources };
}
