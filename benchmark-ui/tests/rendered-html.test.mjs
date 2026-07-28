import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

const previewRoot = new URL("../app/_sites-preview/", import.meta.url);

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the Voiceprint benchmark shell", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Voiceprint — Luxit Inference Lab<\/title>/i);
  assert.match(html, /Luxit inference lab/);
  assert.match(html, /Loading corpus/);
  assert.match(html, /Nothing leaves this Mac/);
  assert.match(html, /Inference matrix/);
  assert.match(html, /Leaderboard/);
  assert.match(html, /Luxit, FluidAudio, PostgreSQL, Kubernetes…/);
  assert.doesNotMatch(html, /private host|current conversation/i);
});

test("keeps recording and results local by construction", async () => {
  const [page, layout, packageJson] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
  ]);

  assert.match(page, /"http:\/\/127\.0\.0\.1:8765"/);
  assert.match(page, /navigator\.mediaDevices\.getUserMedia/);
  assert.match(page, /fetch\(`\$\{API\}\/api\/corpus`/);
  assert.match(page, /fetch\(`\$\{API\}\/api\/recordings/);
  assert.match(page, /fetch\(`\$\{API\}\/api\/jobs/);
  assert.match(page, /Raw audio and results stay in/);
  assert.match(layout, /title:\s*"Voiceprint — Luxit Inference Lab"/);
  assert.match(packageJson, /"private": true/);
  assert.doesNotMatch(page, /private host|current conversation/i);

  await assert.rejects(
    access(new URL("SkeletonPreview.tsx", previewRoot)),
  );
  await assert.rejects(
    access(new URL("preview.css", previewRoot)),
  );
});
