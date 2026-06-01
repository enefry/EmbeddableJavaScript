const defaultInputs = [
  "README.md",
  "docs/design.md",
  "modules/wintertc/README.md",
  "tools/README.md"
];

const inputPaths = process.argv.slice(2);
const files = inputPaths.length > 0 ? inputPaths : defaultInputs;

function byteLength(text) {
  return new TextEncoder().encode(text).byteLength;
}

function hex(buffer) {
  return Array.prototype.map
    .call(new Uint8Array(buffer), (byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function summarizeMarkdown(path, text) {
  const lines = text.split(/\r?\n/);
  const headings = [];
  const links = [];

  for (const line of lines) {
    const heading = /^(#{1,6})\s+(.+?)\s*$/.exec(line);
    if (heading) {
      headings.push({
        level: heading[1].length,
        title: heading[2]
      });
    }

    for (const match of line.matchAll(/\[([^\]]+)\]\(([^)]+)\)/g)) {
      links.push({
        label: match[1],
        target: match[2]
      });
    }
  }

  return {
    path,
    bytes: byteLength(text),
    lines: lines.length,
    headings: headings.slice(0, 8),
    linkCount: links.length,
    hasWinterTC: /\bWinterTC\b/.test(text),
    hasPlatformBoundary: /platform|boundary|provider/i.test(text)
  };
}

async function readInput(path) {
  try {
    const text = await fs.promises.readFile(path, "utf8");
    return {
      ok: true,
      path,
      text,
      summary: summarizeMarkdown(path, text)
    };
  } catch (error) {
    return {
      ok: false,
      path,
      error: error && error.message ? error.message : String(error)
    };
  }
}

const startedAt = performance.now();
const results = [];

for (const path of files) {
  results.push(await readInput(path));
}

const successful = results.filter((item) => item.ok);
const missing = results.filter((item) => !item.ok).map((item) => ({
  path: item.path,
  error: item.error
}));
const combinedText = successful.map((item) => `--- ${item.path} ---\n${item.text}`).join("\n\n");
const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(combinedText));
const nonce = crypto.getRandomValues(new Uint8Array(8));

const runtimeProbe = {
  cli: process.argv[0],
  script: process.argv[1],
  cwd: process.cwd(),
  pid: process.pid,
  winterTCVersion: WinterTC && WinterTC.version,
  hasFetch: typeof fetch === "function",
  hasFs: !!(fs && fs.promises),
  hasCrypto: !!(crypto && crypto.subtle)
};

const probeURL = "data:application/json;charset=utf-8," + encodeURIComponent(JSON.stringify({
  generatedBy: "ejs_apple_cli",
  inputCount: files.length,
  runtimeProbe
}));
const probeResponse = await fetch(probeURL);
const probe = await probeResponse.json();

const report = {
  generatedAt: new Date().toISOString(),
  elapsedMs: Math.round((performance.now() - startedAt) * 1000) / 1000,
  runtimeProbe,
  probe,
  inputCount: files.length,
  successfulCount: successful.length,
  missing,
  totals: {
    bytes: successful.reduce((sum, item) => sum + item.summary.bytes, 0),
    lines: successful.reduce((sum, item) => sum + item.summary.lines, 0),
    linkCount: successful.reduce((sum, item) => sum + item.summary.linkCount, 0)
  },
  digestSHA256: hex(digest),
  nonceHex: hex(nonce),
  documents: successful.map((item) => item.summary)
};

const outputPath = `ejs-cli-repo-report-${process.pid}.json`;
await fs.promises.writeFile(outputPath, JSON.stringify(report, null, 2), {
  root: "tmp",
  flag: "w"
});

await process.stdout.write(JSON.stringify({
  ok: missing.length === 0,
  reportPath: `tmp:${outputPath}`,
  successfulCount: report.successfulCount,
  totals: report.totals,
  digestSHA256: report.digestSHA256.slice(0, 16),
  winterTCVersion: runtimeProbe.winterTCVersion
}) + "\n");
