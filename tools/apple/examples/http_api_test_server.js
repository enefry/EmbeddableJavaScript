(function() {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const maxRequestBytes = 1 * 1024 * 1024;
  const maxRunSeconds = 20;

  const scripts = [
    {
      id: "api_check",
      name: "API 全量检测（推荐先跑）",
      path: "tools/apple/examples/api_check.js",
      category: "总览",
      description: "覆盖 process/system/fs/fetch/workers/crypto 等主要运行时能力（默认跳过网络）。",
      env: {
        EJS_API_CHECK_SKIP_NETWORK: "1"
      }
    },
    {
      id: "repo_report",
      name: "仓库报告示例",
      path: "tools/apple/examples/repo_report.js",
      category: "文档与报告",
      description: "读取多文件并输出摘要信息，适合验证文件读取能力与错误分支。"
    },
    {
      id: "hello_world",
      name: "Hello World",
      path: "tools/apple/examples/hello_world.js",
      category: "运行环境",
      description: "最小脚本执行链路，验证 runtime 能否正常运行脚本。"
    },
    {
      id: "process",
      name: "process API",
      path: "tools/apple/examples/process.js",
      category: "运行环境",
      description: "验证 process.argv / process.cwd / process.pid / env 访问。"
    },
    {
      id: "test-args",
      name: "process.argv",
      path: "tools/apple/examples/test-args.js",
      category: "运行环境",
      description: "验证 argv 结构和传参行为。"
    },
    {
      id: "test-env",
      name: "process.env",
      path: "tools/apple/examples/test-env.js",
      category: "运行环境",
      description: "验证环境变量读取接口。"
    },
    {
      id: "test-system",
      name: "EJSSystem",
      path: "tools/apple/examples/test-system.js",
      category: "系统信息",
      description: "验证平台信息、主机名和用户信息。"
    },
    {
      id: "test-fs",
      name: "fs API",
      path: "tools/apple/examples/test-fs.js",
      category: "文件系统",
      description: "覆盖 mkdir/readFile/writeFile/stat/readdir/unlink/rm。"
    },
    {
      id: "listdir",
      name: "readdir API",
      path: "tools/apple/examples/listdir.js",
      category: "文件系统",
      description: "列目录能力与命令参数处理。"
    },
    {
      id: "resolve",
      name: "EJSPath",
      path: "tools/apple/examples/resolve.js",
      category: "文件系统",
      description: "验证路径 API 的 resolve / basename / dirname / extname。"
    },
    {
      id: "test-fetch",
      name: "fetch API",
      path: "tools/apple/examples/test-fetch.js",
      category: "网络",
      description: "验证 data URL 与 https fetch。按需可关闭网络测试。",
      env: {
        EJS_API_CHECK_SKIP_NETWORK: "0"
      }
    },
    {
      id: "test-storage",
      name: "EJSStorage",
      path: "tools/apple/examples/test-storage.js",
      category: "存储",
      description: "local/json 存储读写与清理路径。"
    },
    {
      id: "test-kv",
      name: "EJSKV",
      path: "tools/apple/examples/test-kv.js",
      category: "存储",
      description: "Key-Value 读写与删除。"
    },
    {
      id: "test-hashing",
      name: "EJSHashing",
      path: "tools/apple/examples/test-hashing.js",
      category: "安全与加密",
      description: "hash/sha256/sha512/digest/base64 行为验证。"
    },
    {
      id: "test-random",
      name: "crypto.getRandomValues",
      path: "tools/apple/examples/test-random.js",
      category: "安全与加密",
      description: "验证随机数 API 与不同 TypedArray 写入。"
    },
    {
      id: "test-uuid",
      name: "EJSUUID",
      path: "tools/apple/examples/test-uuid.js",
      category: "安全与加密",
      description: "v4/randomUUID 与校验规则验证。"
    },
    {
      id: "test-timer",
      name: "Timer API",
      path: "tools/apple/examples/test-timer.js",
      category: "并发与时间",
      description: "setTimeout + queueMicrotask 时序行为。"
    },
    {
      id: "hello_workers",
      name: "Worker hello",
      path: "tools/apple/examples/hello_workers.js",
      category: "Worker",
      description: "验证主子线程通信与超时控制。"
    },
    {
      id: "worker",
      name: "worker helper（仅子线程脚本）",
      path: "tools/apple/examples/worker.js",
      category: "Worker",
      description: "辅助 worker 入口，默认不提供独立执行按钮。",
      canRun: false
    }
  ];

  const indexHtml = `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>EJS Runtime Web Test Console</title>
  <style>
    :root { --bg:#f6f7fb; --card:#ffffff; --txt:#1f2937; --muted:#6b7280; --ok:#166534; --bad:#991b1b; --line:#e5e7eb; --warn:#92400e; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; margin: 0; background: var(--bg); color: var(--txt); }
    .container { max-width: 980px; margin: 20px auto; padding: 0 16px; }
    .header { display:flex; align-items:center; justify-content:space-between; margin-bottom: 16px; }
    .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 16px; margin-bottom: 16px; }
    .row { display:flex; gap: 12px; flex-wrap: wrap; }
    button { border: none; background:#2563eb; color:#fff; border-radius: 8px; padding: 8px 12px; cursor: pointer; }
    button.secondary { background:#0f766e; }
    button.warn { background:#b45309; }
    .muted { color: var(--muted); font-size: 12px; }
    .script { border:1px solid var(--line); border-radius: 8px; padding: 12px; margin-bottom: 10px; }
    .section { margin-bottom: 16px; }
    .section-title { display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; border-bottom:1px solid var(--line); padding-bottom:4px; }
    .script-title { font-weight: 600; margin: 0 0 4px; }
    .script { border:1px solid var(--line); border-radius: 8px; padding: 12px; margin-bottom: 10px; }
    .script h4 { margin: 0 0 4px; }
    .status { font-size: 12px; margin-top: 6px; }
    .ok { color: var(--ok); }
    .bad { color: var(--bad); }
    .warn { color: var(--warn); }
    pre { white-space: pre-wrap; background:#0f172a; color:#f8fafc; border-radius: 8px; padding: 12px; max-height: 320px; overflow:auto; }
    table { width: 100%; border-collapse: collapse; table-layout: fixed; }
    th, td { font-size: 13px; text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--line); word-wrap: break-word; }
    th { font-weight: 700; color: var(--muted); background: #f9fafb; }
    .mono { font-family: ui-monospace, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h2>EJS Runtime Web 测试面板</h2>
      <button id="refresh">刷新脚本列表</button>
    </div>
    <div class="card">
      <div id="scripts" style="margin-bottom:8px;"></div>
      <div class="row" style="margin-top:12px;">
        <button id="run-all" class="secondary">运行 API 全量检测</button>
        <button id="run-all-visible" class="warn">运行所有分类脚本</button>
        <span id="loading" class="muted"></span>
      </div>
    </div>
    <div class="card">
      <h3>最近运行结果</h3>
      <div id="runMeta" class="muted"></div>
      <div id="run-history-empty" class="muted">暂无执行记录</div>
      <div style="overflow:auto;">
        <table id="history-table" style="display:none;">
          <thead>
            <tr>
              <th style="width:155px;">时间</th>
              <th style="width:100px;">状态</th>
              <th style="width:170px;">脚本</th>
              <th style="width:90px;">分类</th>
              <th style="width:80px;">耗时(ms)</th>
              <th style="width:90px;">退出码</th>
              <th>输出摘要</th>
            </tr>
          </thead>
          <tbody id="history-body"></tbody>
        </table>
      </div>
      <pre id="output">尚未执行</pre>
    </div>
  </div>
    <script>
      const scriptsNode = document.getElementById('scripts');
      const output = document.getElementById('output');
      const runMeta = document.getElementById('runMeta');
      const loading = document.getElementById('loading');
      const historyEmpty = document.getElementById('run-history-empty');
      const historyTable = document.getElementById('history-table');
      const historyBody = document.getElementById('history-body');
      const runAllVisibleBtn = document.getElementById('run-all-visible');
      const categoryOrder = ["总览", "运行环境", "系统信息", "文件系统", "网络", "并发与时间", "安全与加密", "存储", "Worker", "文档与报告", "未分类"];
      let scriptStateById = {};
      let scriptCatalog = [];
      let runHistory = [];
      const maxHistoryRows = 50;

      function formatTime(ts) {
        const date = new Date(ts);
        const pad = (v) => String(v).padStart(2, "0");
        return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + " " + pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
      }

      function formatMs(ms) {
        if (typeof ms === "undefined" || ms === null) return "-";
        return Number(ms).toFixed(1);
      }

      function escapeHtml(value) {
        return String(value)
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;")
          .replace(/"/g, "&quot;")
          .replace(/'/g, "&#39;");
      }

      function shortText(text, maxLength) {
        const source = String(text || "").replace(/\s+/g, " ").trim();
        if (source.length <= maxLength) return source;
        return source.slice(0, maxLength - 1) + "…";
      }

      function renderScriptList(items) {
        scriptsNode.innerHTML = "";
        const grouped = {};
        for (const item of items) {
          const cat = item.category || "未分类";
          (grouped[cat] || (grouped[cat] = [])).push(item);
        }
        const orderedCats = categoryOrder.filter((cat) => grouped[cat] && grouped[cat].length > 0);
        for (const extra of Object.keys(grouped).filter((cat) => orderedCats.indexOf(cat) === -1)) {
          orderedCats.push(extra);
        }

        for (const category of orderedCats) {
          const list = grouped[category] || [];
          const section = document.createElement('div');
          section.className = 'section';
          section.innerHTML =
            '<div class="section-title"><h3 style="margin:0;">' + category + '</h3>' +
            '<span class="muted">' + list.length + '项</span></div>';
          const container = document.createElement('div');
          for (const item of list) {
            const last = scriptStateById[item.id] || {};
            const status = last.ok == null ? "未运行" : (last.ok ? "PASS" : "FAIL");
            const statusClass = last.ok == null ? "warn" : (last.ok ? "ok" : "bad");
            const canRun = item.canRun === false ? false : true;
            const statusText = '<span class="' + statusClass + '">' + status + '</span>' +
              (typeof last.durationMs === "number" ? " / " + formatMs(last.durationMs) + "ms" : "") +
              (typeof last.exitCode === "number" ? " / exit " + last.exitCode : "");
            const action = canRun
              ? '<button class="run-btn" data-id="' + item.id + '">运行</button>'
              : '<span class="muted">不可直接运行</span>';
            const el = document.createElement('div');
            el.className = 'script';
            el.innerHTML = '<div class="script-title">' + item.name + '</div>' +
              '<div class="muted">' + (item.description || "") + '</div>' +
              '<div class="muted" style="margin-top:6px;">path: ' + item.path + '</div>' +
              '<div class="row" style="margin-top:8px;">' + action + statusText + '</div>' +
              '<div class="status"></div>';
            const btn = el.querySelector('.run-btn');
            const statusNode = el.querySelector('.status');
            if (btn) {
              btn.onclick = async () => {
                await runScript(item.id, statusNode, item.name);
              };
            }
            container.appendChild(el);
          }
          section.appendChild(container);
          scriptsNode.appendChild(section);
        }
      }

      function renderHistory(records) {
        if (!records || records.length === 0) {
          historyEmpty.style.display = "";
          historyTable.style.display = "none";
          return;
        }
        historyEmpty.style.display = "none";
        historyTable.style.display = "";
        historyBody.innerHTML = "";
        for (const row of records) {
          const tr = document.createElement('tr');
          const statusClass = row.ok ? 'ok' : 'bad';
          const outputPreview = row.summary != null
            ? JSON.stringify(row.summary)
            : shortText(row.output, 120);
          tr.innerHTML =
            '<td class="mono">' + formatTime(row.ts) + '</td>' +
            '<td class="' + statusClass + '">' + (row.ok ? "PASS" : "FAIL") + '</td>' +
            '<td class="mono">' + (row.name || row.id) + '</td>' +
            '<td class="mono">' + (row.category || "未分类") + '</td>' +
            '<td class="mono">' + formatMs(row.durationMs) + '</td>' +
            '<td class="mono">' + (typeof row.exitCode === "number" ? row.exitCode : "-") + '</td>' +
            '<td class="mono">' + escapeHtml(outputPreview) + '</td>';
          historyBody.appendChild(tr);
        }
      }

      async function loadScripts() {
        scriptsNode.innerHTML = "加载中...";
        const res = await fetch('/api/examples');
        const data = await res.json();
        scriptStateById = {};
        scriptCatalog = Array.isArray(data.scripts) ? data.scripts : [];
        renderScriptList(scriptCatalog);
      }

      async function runScript(id, statusNode, name) {
        try {
          loading.textContent = "运行中: " + id;
          output.textContent = '执行中...';
          runMeta.textContent = '';
          if (statusNode) statusNode.textContent = '执行中';

          const res = await fetch('/api/run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ scriptId: id })
          });
          const data = await res.json();
          const latest = Object.assign({}, data, {
            id,
            name: name || id,
            ts: Date.now()
          });

          let category = "未分类";
          const known = scriptCatalog.find((entry) => entry.id === id);
          if (known) {
            category = known.category || category;
          }
          latest.category = category;

          scriptStateById[id] = latest;
          runHistory.unshift(latest);
          if (runHistory.length > maxHistoryRows) runHistory.pop();

          const passed = data.ok ? 'PASS' : 'FAIL';
          const cls = data.ok ? 'ok' : 'bad';
          if (statusNode) statusNode.innerHTML = '<span class="' + cls + '">' + passed + '</span>  elapsed=' + data.durationMs + 'ms';
          runMeta.innerHTML = '<span class="' + cls + '">' + passed + '</span> ' + id + ' | elapsed ' + data.durationMs + 'ms | exit=' + data.exitCode;
          output.textContent = data.output || JSON.stringify(data, null, 2);
          renderScriptList(scriptCatalog);
          renderHistory(runHistory);
      } catch (error) {
          if (statusNode) statusNode.textContent = "失败: " + String(error);
          output.textContent = String(error);
        } finally {
          loading.textContent = '';
        }
      }

      async function runAllVisibleScripts() {
        const runnable = scriptCatalog.filter((entry) => entry.canRun !== false);
        for (const item of runnable) {
          const allStatus = document.querySelector('[data-id=\"' + item.id + '\"]');
          const targetStatus = allStatus ? allStatus.parentElement.parentElement.querySelector('.status') : null;
          await runScript(item.id, targetStatus, item.name);
        }
      }

    document.getElementById('run-all').onclick = () => runScript('api_check');
    document.getElementById('run-all-visible').onclick = runAllVisibleScripts;
    renderHistory([]);
    document.getElementById('refresh').onclick = loadScripts;
    loadScripts();
  </script>
</body>
</html>`;

  function textFromBuffer(buffer) {
    return decoder.decode(buffer || new ArrayBuffer(0));
  }

  function concatBuffers(left, right) {
    const merged = new Uint8Array((left ? left.length : 0) + (right ? right.length : 0));
    if (left) merged.set(left, 0);
    if (right) merged.set(right, left ? left.length : 0);
    return merged;
  }

  function toBytes(input) {
    if (input instanceof ArrayBuffer) {
      return new Uint8Array(input);
    }
    if (ArrayBuffer.isView(input)) {
      return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    }
    return encoder.encode(typeof input === "string" ? input : JSON.stringify(input));
  }

  function buildResponse(statusCode, bodyText, contentType = "text/plain; charset=utf-8") {
    const body = toBytes(bodyText);
    const head = [
      `HTTP/1.1 ${statusCode} ${statusText(statusCode)}`,
      `content-type: ${contentType}`,
      `content-length: ${body.length}`,
      "connection: close",
      "",
      ""
    ].join("\r\n");
    const headBytes = encoder.encode(head);
    const packet = new Uint8Array(headBytes.length + body.length);
    packet.set(headBytes, 0);
    packet.set(body, headBytes.length);
    return packet;
  }

  function parseRequest(raw) {
    const text = textFromBuffer(raw);
    const boundary = text.indexOf("\r\n\r\n");
    if (boundary < 0) {
      return null;
    }

    const headerText = text.slice(0, boundary);
    const bodyText = text.slice(boundary + 4);
    const [startLine, ...headerLines] = headerText.split("\r\n");
    const [method, target] = startLine.split(" ");

    const headers = {};
    for (const headerLine of headerLines) {
      const sep = headerLine.indexOf(":");
      if (sep < 0) continue;
      const key = headerLine.slice(0, sep).trim().toLowerCase();
      const value = headerLine.slice(sep + 1).trim();
      headers[key] = value;
    }

    const [pathRaw] = target.split("?");
    const path = pathRaw || "/";
    const contentLength = Number(headers["content-length"] || 0);

    return { method: method || "GET", path, headers, contentLength, bodyText };
  }

  async function readRequest(socket) {
    let buffer = new Uint8Array(0);
    let request = null;

    while (buffer.length <= maxRequestBytes) {
      const chunk = await socket.read({ maxBytes: 8192 });
      if (!(chunk && chunk.length > 0)) {
        throw new Error("连接已关闭");
      }
      buffer = concatBuffers(buffer, chunk);
      request = parseRequest(buffer);
      if (!request) continue;

      const bodyStart = textFromBuffer(buffer).indexOf("\r\n\r\n") + 4;
      const bodyLength = buffer.length - bodyStart;
      if (bodyLength >= request.contentLength) {
        request.body = textFromBuffer(buffer.slice(bodyStart, bodyStart + request.contentLength));
        break;
      }
    }

    if (buffer.length > maxRequestBytes) {
      throw new Error("请求体过大");
    }

    if (request == null) {
      throw new Error("无效请求");
    }
    return request;
  }

  function json(statusCode, data) {
    return buildResponse(statusCode, JSON.stringify(data), "application/json; charset=utf-8");
  }

  function text(statusCode, content, contentType = "text/plain; charset=utf-8") {
    return buildResponse(statusCode, content, contentType);
  }

  function statusText(code) {
    if (code === 200) return "OK";
    if (code === 400) return "Bad Request";
    if (code === 404) return "Not Found";
    if (code === 408) return "Request Timeout";
    if (code === 429) return "Too Many Requests";
    if (code === 500) return "Internal Server Error";
    return "OK";
  }

  function cloneLogOutput(collected) {
    return collected.map((item) => item.text).join("");
  }

  async function runScript(script, options) {
    const source = await fs.promises.readFile(script.path, "utf8");
    const outputs = [];
    const startAt = performance.now();

    const runEnv = Object.assign({
      EJS_TEST_RUNNER: "1"
    }, script.env || {}, options && options.env || {});

    const consoleState = globalThis.console;
    const processState = globalThis.process;
    const ejsProcessState = globalThis.EJS && globalThis.EJS.process;

    const envBase = (() => {
      if (!processState || typeof processState.env !== "function") return {};
      try {
        return processState.env() || {};
      } catch (_e) {
        return {};
      }
    })();

    function buildWriteCapture(channel) {
      return async function(value) {
        const bytes = value instanceof ArrayBuffer
          ? new Uint8Array(value)
          : (ArrayBuffer.isView(value)
              ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
              : (typeof value === "string" ? encoder.encode(value) : encoder.encode(JSON.stringify(value))));
        const text = decoder.decode(bytes);
        outputs.push({
          ts: Date.now(),
          type: channel,
          text
        });
        return {
          ok: true,
          bytesWritten: bytes.length
        };
      };
    }

    const patchedConsole = {};
    const methods = ["log", "info", "warn", "error", "debug"];
    for (const method of methods) {
      const original = consoleState && consoleState[method];
      patchedConsole[method] = (...args) => {
        outputs.push({
          ts: Date.now(),
          type: `console.${method}`,
          text: args.map((item) => {
            if (typeof item === "string") return item;
            try {
              return JSON.stringify(item);
            } catch (_e) {
              return String(item);
            }
          }).join(" ") + "\n"
        });
        if (typeof original === "function") {
          original.apply(consoleState, args);
        }
      };
    }

    let exitState = { called: false, code: 0, message: "" };
    const processShim = {
      get argv() {
        return processState ? processState.argv : ["ejs_apple_cli", script.path];
      },
      get pid() {
        return processState ? processState.pid : 0;
      },
      cwd() {
        return processState ? processState.cwd() : ".";
      },
      env(name) {
        if (typeof name === "undefined") {
          return Object.assign({}, envBase, runEnv);
        }
        if (runEnv[name] !== undefined) return runEnv[name];
        return processState && processState.env ? processState.env(name) : undefined;
      },
      exit(code, message) {
        exitState = {
          called: true,
          code: Number.isFinite(Number(code)) ? Number(code) : 1,
          message: String(message || "")
        };
        const err = new Error(exitState.message || `process.exit(${exitState.code})`);
        err.__ejsRunExit = true;
        throw err;
      },
      stdout: {
        write(value) {
          return buildWriteCapture("stdout")(value);
        }
      },
      stderr: {
        write(value) {
          return buildWriteCapture("stderr")(value);
        }
      }
    };

    try {
      Object.defineProperty(globalThis, "console", {
        configurable: true,
        writable: true,
        value: patchedConsole
      });
      Object.defineProperty(globalThis, "process", {
        configurable: true,
        writable: true,
        value: processShim
      });
      if (globalThis.EJS && typeof globalThis.EJS === "object") {
        Object.defineProperty(globalThis.EJS, "process", {
          configurable: true,
          writable: true,
          value: processShim
        });
      }

      const wrapped = `(async () => {\n${source}\n})();`;
      const runner = new Function(wrapped);
      await runner();
    } catch (error) {
      if (error && error.__ejsRunExit) {
        if (error.message) {
          outputs.push({
            ts: Date.now(),
            type: "system",
            text: `intercepted process.exit(${exitState.code}): ${error.message}\n`
          });
        }
      } else {
        exitState.called = true;
        exitState.code = 1;
        outputs.push({
          ts: Date.now(),
          type: "system",
          text: `${error && error.stack ? error.stack : String(error)}\n`
        });
      }
    } finally {
      Object.defineProperty(globalThis, "console", {
        configurable: true,
        writable: true,
        value: consoleState
      });
      Object.defineProperty(globalThis, "process", {
        configurable: true,
        writable: true,
        value: processState
      });
      if (globalThis.EJS && typeof globalThis.EJS === "object") {
        Object.defineProperty(globalThis.EJS, "process", {
          configurable: true,
          writable: true,
          value: ejsProcessState
        });
      }
    }

    const outputText = cloneLogOutput(outputs);
    const lines = outputText.split(/\r?\n/).reverse();
    let summary = null;
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed[0] !== "{") continue;
      try {
        summary = JSON.parse(trimmed);
        break;
      } catch (_e) {
        // ignore
      }
    }

    return {
      ok: !exitState.code,
      exitCode: exitState.code,
      script: script.id,
      path: script.path,
      durationMs: Math.round((performance.now() - startAt) * 1000) / 1000,
      output: outputText,
      summary
    };
  }

  let runnerQueue = Promise.resolve();

  function withLock(task) {
    const next = runnerQueue.then(task, task);
    runnerQueue = next.then(() => null, () => null);
    return next;
  }

  async function handleRequest(socket, request) {
    if (request.path === "/" || request.path === "") {
      await socket.write(text(200, indexHtml, "text/html; charset=utf-8"));
      return;
    }

    if (request.path === "/api/examples") {
      const payload = {
        ok: true,
        scripts
      };
      await socket.write(json(200, payload));
      return;
    }

    if (request.path === "/api/run" && request.method === "POST") {
      const body = request.body || "{}";
      let params = {};
      try {
        params = body ? JSON.parse(body) : {};
      } catch (_error) {
        await socket.write(json(400, { ok: false, error: "invalid JSON body" }));
        return;
      }

      const script = scripts.find((entry) => entry.id === params.scriptId);
      if (!script) {
        await socket.write(json(404, { ok: false, error: "scriptId not found" }));
        return;
      }

      const result = await withLock(() => runScript(script, params));
      await socket.write(json(200, result));
      return;
    }

    await socket.write(json(404, { ok: false, error: "not found" }));
  }

  function describeRuntimeError(error) {
    if (error == null) return {};
    if (typeof error !== "object") return { message: String(error) };

    const fields = {};
    const keys = [
      "name",
      "code",
      "message",
      "operation",
      "syscall",
      "address",
      "port",
      "host",
      "family",
      "nativeDomain",
      "nativeCode"
    ];

    for (const key of keys) {
      if (Object.prototype.hasOwnProperty.call(error, key)) {
        const value = error[key];
        if (typeof value !== "undefined" && value !== null) {
          fields[key] = value;
        }
      }
    }

    return fields;
  }

  (async function() {
    const host = (process.env && process.env("EJS_HTTP_TEST_HOST")) || "0.0.0.0";
    const portEnv = (process.env && process.env("EJS_HTTP_TEST_PORT")) || "8080";
    const port = Number(portEnv) || 8080;

    const listener = await EJSNet.tcp.listen({
      host,
      port,
      family: 0,
      backlog: 128,
      reuseAddress: true
    });

    console.log(`tcp http server started: ${host}:${listener.localAddress.port}`);

    while (true) {
      let socket = null;
      try {
        socket = await listener.accept({ timeoutMs: 30000 });
        const request = await readRequest(socket);
        await handleRequest(socket, request);
      } catch (error) {
        try {
          const message = String(error && error.message ? error.message : error || "network error");
          await socket.write(text(500, JSON.stringify({ ok: false, error: message })));
        } catch (_error) {
          // ignore
        }
      } finally {
        try {
          if (socket) {
            await socket.close();
          }
        } catch (_error) {
          // ignore
        }
      }
    }
  })().catch(async (error) => {
    const detail = describeRuntimeError(error);
    await process.stdout.write(`http server exited: ${error && error.stack ? error.stack : String(error)}\n`);
    if (Object.keys(detail).length > 0) {
      await process.stdout.write(`http server exit detail: ${JSON.stringify(detail)}\n`);
    }
    process.exit(1);
  });
})();
