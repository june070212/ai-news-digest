// main.js — renders the prerendered digest in assets/data.json.
//
// The digest is fetched and ranked at build time (scripts/build-digest.mjs),
// because GitHub Pages is static and the upstream feeds send no CORS headers.
// Everything here is display + client-side filtering over that JSON.

const $ = (id) => document.getElementById(id);

/* Theme toggle — persisted, matches the no-flash script in the <head>. */
const toggle = $("theme-toggle");
const paintToggle = () => {
  toggle.textContent = document.documentElement.getAttribute("data-theme") === "light" ? "☾" : "☀";
};
toggle.addEventListener("click", () => {
  const next = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
  document.documentElement.setAttribute("data-theme", next);
  try { localStorage.setItem("theme", next); } catch {}
  paintToggle();
});
paintToggle();

const state = { digest: null, query: "", org: "", importance: "", tag: "", sort: "rank" };

const RELATIVE = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
const UNITS = [
  ["day", 86400000],
  ["hour", 3600000],
  ["minute", 60000],
];

function timeAgo(iso) {
  if (!iso) return "undated";
  const diff = new Date(iso).getTime() - Date.now();
  for (const [unit, ms] of UNITS) {
    if (Math.abs(diff) >= ms || unit === "minute") {
      return RELATIVE.format(Math.round(diff / ms), unit);
    }
  }
  return "just now";
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function matches(story) {
  if (state.org && story.org !== state.org) return false;
  if (state.importance && story.importance !== state.importance) return false;
  if (state.tag && !story.tags.includes(state.tag)) return false;
  if (state.query) {
    const hay = `${story.title} ${story.summary} ${story.source} ${story.tags.join(" ")}`.toLowerCase();
    if (!state.query.split(/\s+/).every((term) => hay.includes(term))) return false;
  }
  return true;
}

function visibleStories() {
  const list = state.digest.stories.filter(matches);
  if (state.sort === "date") {
    list.sort((a, b) => String(b.published ?? "").localeCompare(String(a.published ?? "")));
  }
  return list;
}

function storyCard(story) {
  const li = el("li", `story imp-${story.importance}`);

  const meta = el("div", "story-meta");
  meta.append(
    el("span", `badge badge-${story.importance}`, story.importance),
    el("span", "chip", story.org),
    el("span", "dot", "·"),
    el("span", "src", story.source),
    el("span", "dot", "·"),
    el("time", "when", timeAgo(story.published)),
  );
  if (story.published) meta.querySelector("time").dateTime = story.published;

  const link = el("a", "story-title", story.title);
  link.href = story.url;
  link.target = "_blank";
  link.rel = "noopener";

  const heading = el("h3", "story-heading");
  heading.append(link);
  li.append(meta, heading);
  if (story.summary) li.append(el("p", "story-summary", story.summary));

  if (story.tags.length) {
    const tags = el("div", "tags");
    for (const tag of story.tags) {
      const btn = el("button", "tag", tag);
      btn.type = "button";
      // Tag chips double as a one-click filter.
      btn.addEventListener("click", () => {
        state.tag = state.tag === tag ? "" : tag;
        $("f-tag").value = state.tag;
        renderStories();
      });
      tags.append(btn);
    }
    li.append(tags);
  }
  return li;
}

function renderStories() {
  const list = visibleStories();
  const host = $("stories");
  host.replaceChildren(...list.map(storyCard));
  $("empty").hidden = list.length > 0;
  const total = state.digest.stories.length;
  $("count").textContent =
    list.length === total ? `${total} stories` : `${list.length} of ${total} stories`;
}

function renderSummary() {
  const d = state.digest;
  $("m-total").textContent = d.totals.stories;
  $("m-high").textContent = d.totals.high;
  $("m-github").textContent = d.totals.github;
  $("m-microsoft").textContent = d.totals.microsoft;

  const built = new Date(d.generatedAt);
  $("stamp").textContent =
    `Last ${d.window.days} days · rebuilt ${timeAgo(d.generatedAt)} (${built.toISOString().replace("T", " ").slice(0, 16)} UTC)`;

  $("tldr").replaceChildren(
    ...d.stories
      .filter((s) => s.importance === "high")
      .slice(0, 5)
      .map((s) => {
        const li = el("li");
        const a = el("a", null, s.title);
        a.href = s.url;
        a.target = "_blank";
        a.rel = "noopener";
        li.append(a, el("span", "tldr-src", ` — ${s.source}`));
        return li;
      }),
  );

  const tagSelect = $("f-tag");
  for (const { tag, count } of d.tags) {
    const opt = el("option", null, `${tag} (${count})`);
    opt.value = tag;
    tagSelect.append(opt);
  }

  $("sources").replaceChildren(
    ...d.sources.map((s) => {
      const li = el("li", `source ${s.ok ? "ok" : "err"}`);
      li.append(
        el("span", "source-dot", s.ok ? "●" : "✕"),
        el("span", "source-label", s.label),
        el("span", "chip", s.org),
        el("span", "source-count", s.ok ? `${s.count} stories` : s.error || "unavailable"),
      );
      return li;
    }),
  );
}

function wireFilters() {
  const bind = (id, key) =>
    $(id).addEventListener("input", (e) => {
      state[key] = key === "query" ? e.target.value.trim().toLowerCase() : e.target.value;
      renderStories();
    });
  bind("f-query", "query");
  bind("f-org", "org");
  bind("f-importance", "importance");
  bind("f-tag", "tag");
  bind("f-sort", "sort");
  $("f-reset").addEventListener("click", () => {
    Object.assign(state, { query: "", org: "", importance: "", tag: "", sort: "rank" });
    for (const id of ["f-query", "f-org", "f-importance", "f-tag", "f-sort"]) $(id).value = "";
    $("f-sort").value = "rank";
    renderStories();
  });
}

async function main() {
  try {
    // Cache-bust so a fresh deploy isn't masked by a stale CDN copy.
    const res = await fetch(`./assets/data.json?v=${Date.now()}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    state.digest = await res.json();
  } catch (err) {
    $("stamp").textContent = `Couldn't load the digest: ${err.message}`;
    $("stamp").classList.add("error");
    return;
  }
  renderSummary();
  wireFilters();
  renderStories();
}

main();
