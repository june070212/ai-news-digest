// net.mjs — hardened fetch for outbound feed requests.
//
// The feed list is fixed and compiled into the image, so the real risk here is a
// slow or hostile upstream rather than SSRF. We still pin the allowed hosts and
// always bound the request with a timeout so a stalled feed can't pile up
// in-flight requests inside the pod.

const ALLOWED_HOSTS = new Set([
  "github.blog",
  "devblogs.microsoft.com",
  "developer.microsoft.com",
  "azure.microsoft.com",
  "www.microsoft.com",
]);

const TIMEOUT_MS = Number(process.env.FEED_TIMEOUT_MS || 12000);

export function assertAllowedUrl(url) {
  const parsed = new URL(url);
  if (parsed.protocol !== "https:") throw new Error(`refusing non-https url: ${url}`);
  if (!ALLOWED_HOSTS.has(parsed.hostname)) throw new Error(`host not allow-listed: ${parsed.hostname}`);
  return parsed;
}

export async function safeFetch(url, init = {}) {
  assertAllowedUrl(url);
  return fetch(url, {
    redirect: "follow",
    ...init,
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
}
