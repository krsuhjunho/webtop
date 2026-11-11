// Headless check that the first trusted click enables Kasm audio exactly once.
// A stub audio() matches the real client: the first call creates an
// AudioContext, the second call destroys it.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const playwright = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const chromium = playwright.chromium || playwright.default.chromium;

const here = dirname(fileURLToPath(import.meta.url));
const script = await readFile(join(here, "../kasm/webtop-audio.js"));

const parentHtml = `<!DOCTYPE html>
<html>
  <body>
    <button id="outside" type="button">outside</button>
    <iframe id="vnc" src="/vnc.html"></iframe>
    <img id="audioButton" alt="audio" onclick="audio()">
    <script>
      var player = {};
      var audioCalls = 0;
      function audio() {
        audioCalls += 1;
        var button = document.getElementById("audioButton");
        if (player.audioCtx) {
          player.audioCtx.close();
          player = {};
          button.classList.remove("icons-selected");
          return;
        }
        var Ctx = window.AudioContext || window.webkitAudioContext;
        player = { audioCtx: new Ctx() };
        player.audioCtx.resume();
        button.classList.add("icons-selected");
      }
    </script>
    <script src="/webtop-audio.js"></script>
  </body>
</html>`;

const frameHtml = `<!DOCTYPE html>
<html>
  <body>
    <button id="desk" type="button">desktop</button>
    <script src="/webtop-audio.js"></script>
  </body>
</html>`;

const server = createServer((req, res) => {
  if (req.url.startsWith("/webtop-audio.js")) {
    res.setHeader("content-type", "text/javascript");
    res.end(script);
    return;
  }
  if (req.url.startsWith("/vnc.html")) {
    res.setHeader("content-type", "text/html");
    res.end(frameHtml);
    return;
  }
  res.setHeader("content-type", "text/html");
  res.end(parentHtml);
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const url = `http://127.0.0.1:${port}/`;

const browser = await chromium.launch({
  headless: true,
  args: ["--autoplay-policy=document-user-activation-required"],
});

function snapshot(page) {
  return page.evaluate(() => ({
    calls: window.audioCalls,
    selected: document.getElementById("audioButton").classList.contains("icons-selected"),
    state: window.player && window.player.audioCtx ? window.player.audioCtx.state : "none",
  }));
}

const results = [];
try {
  const page = await browser.newPage();
  await page.goto(url);
  await page.frameLocator("#vnc").locator("#desk").waitFor();
  await page.waitForFunction(() => window.__webtopAudioHook === true);
  await page.frames()[1].waitForFunction(() => window.__webtopAudioHook === true);
  const before = await snapshot(page);
  results.push(["before any gesture", before]);
  if (before.calls !== 0 || before.state !== "none") {
    throw new Error("audio started before a gesture: " + JSON.stringify(before));
  }

  await page.frameLocator("#vnc").locator("#desk").click();
  const afterClick = await snapshot(page);
  results.push(["click inside vnc iframe", afterClick]);
  if (afterClick.calls !== 1 || !afterClick.selected) {
    throw new Error("iframe click did not enable audio once: " + JSON.stringify(afterClick));
  }
  if (afterClick.state !== "running") {
    throw new Error("AudioContext was not running after the iframe click: " + JSON.stringify(afterClick));
  }

  await page.frameLocator("#vnc").locator("#desk").click();
  const afterSecond = await snapshot(page);
  results.push(["second iframe click", afterSecond]);
  if (afterSecond.calls !== 1 || !afterSecond.selected || afterSecond.state !== "running") {
    throw new Error("second gesture toggled audio: " + JSON.stringify(afterSecond));
  }

  const parentClick = await browser.newPage();
  await parentClick.goto(url);
  await parentClick.locator("#outside").click();
  const outside = await snapshot(parentClick);
  results.push(["click on parent page", outside]);
  if (outside.calls !== 1 || outside.state !== "running") {
    throw new Error("parent click did not enable audio: " + JSON.stringify(outside));
  }

  const buttonPage = await browser.newPage();
  await buttonPage.goto(url);
  await buttonPage.locator("#audioButton").click();
  const button = await snapshot(buttonPage);
  results.push(["speaker button", button]);
  if (button.calls !== 1 || !button.selected || button.state !== "running") {
    throw new Error("speaker button was double-toggled: " + JSON.stringify(button));
  }

  const keyPage = await browser.newPage();
  await keyPage.goto(url);
  await keyPage.frameLocator("#vnc").locator("#desk").focus();
  await keyPage.keyboard.press("a");
  const keyed = await snapshot(keyPage);
  results.push(["keypress after focus", keyed]);
  if (keyed.calls !== 1 || keyed.state !== "running") {
    throw new Error("keypress did not enable audio: " + JSON.stringify(keyed));
  }
} finally {
  console.log(JSON.stringify(results, null, 2));
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}

console.log("audio gesture ok");
