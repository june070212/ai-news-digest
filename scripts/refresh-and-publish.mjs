#!/usr/bin/env node
// refresh-and-publish.mjs — rebuild the digest and push it to the Pages branch.
//
// This is the scheduled path. GitHub Actions would normally do this, but the
// deploy workflow can't be pushed without the `workflow` OAuth scope, so the
// rebuild runs locally and publishes the result as a plain commit instead.
//
// Safe to run repeatedly: it stages only assets/data.json and exits without a
// commit when the digest is unchanged.

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const ROOT = path.resolve(fileURLToPath(new URL("../", import.meta.url)));
const DATA = path.join(ROOT, "assets", "data.json");
const BRANCH = process.env.DIGEST_BRANCH || "main";

async function run(cmd, args, opts = {}) {
  const { stdout } = await execFileAsync(cmd, args, { cwd: ROOT, maxBuffer: 16 * 1024 * 1024, ...opts });
  return stdout.trim();
}

const git = (...args) => run("git", args);

// The push needs an explicit token: the macOS keychain still holds a credential
// for a different account, and git prefers it over the active gh login.
async function pushWithToken() {
  const token = await run("gh", ["auth", "token"], {
    env: { ...process.env, GH_TOKEN: undefined, GITHUB_TOKEN: undefined },
  });
  if (!token) throw new Error("no gh token available; run `gh auth login`");
  const basic = Buffer.from(`x-access-token:${token}`).toString("base64");
  await git(
    "-c", "credential.helper=",
    "-c", `http.https://github.com/.extraheader=Authorization: Basic ${basic}`,
    "push", "origin", `HEAD:${BRANCH}`
  );
}

async function summarize() {
  const data = JSON.parse(await readFile(DATA, "utf8"));
  const healthy = data.sources.filter((s) => s.ok).length;
  return {
    generatedAt: data.generatedAt,
    stories: data.stories.length,
    healthy,
    sources: data.sources.length,
    failed: data.sources.filter((s) => !s.ok).map((s) => `${s.id}: ${s.error}`),
  };
}

async function main() {
  // Refuse to publish from a dirty tree: a scheduled job must never sweep up
  // unrelated edits that happen to be sitting in the worktree.
  const dirty = (await git("status", "--porcelain", "--", ".")).split("\n").filter(Boolean)
    .filter((line) => !line.endsWith("assets/data.json") && !line.includes(".github/"));
  if (dirty.length) throw new Error(`worktree has unrelated changes:\n${dirty.join("\n")}`);

  await git("fetch", "origin", BRANCH);
  const behind = await git("rev-list", "--count", `HEAD..origin/${BRANCH}`);
  if (behind !== "0") {
    // Only data.json is ever committed here, so a fast-forward is always safe.
    await git("merge", "--ff-only", `origin/${BRANCH}`);
  }

  await run("node", [path.join(ROOT, "scripts", "build-digest.mjs")]);
  const summary = await summarize();
  if (summary.healthy === 0) throw new Error("no feeds were reachable; refusing to publish");

  await git("add", "--", "assets/data.json");
  const staged = await git("diff", "--cached", "--name-only");
  if (!staged) {
    console.log(`No change — digest already current (${summary.stories} stories, ${summary.healthy}/${summary.sources} feeds).`);
    return;
  }

  const stamp = summary.generatedAt.replace("T", " ").slice(0, 16);
  const message = [
    `Refresh digest (${stamp} UTC)`,
    "",
    `${summary.stories} stories from ${summary.healthy}/${summary.sources} healthy feeds.`,
    summary.failed.length ? `Unreachable: ${summary.failed.join("; ")}` : null,
    "",
    "Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>",
  ].filter((line) => line !== null).join("\n");

  await git("commit", "-m", message);
  await pushWithToken();
  console.log(`Published ${summary.stories} stories (${summary.healthy}/${summary.sources} feeds) at ${summary.generatedAt}.`);
  if (summary.failed.length) console.log(`Unreachable feeds: ${summary.failed.join("; ")}`);
}

main().catch((err) => {
  console.error(`refresh failed: ${err.message}`);
  process.exit(1);
});
