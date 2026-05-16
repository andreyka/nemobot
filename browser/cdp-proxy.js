#!/usr/bin/env node
const http = require("http");
const net = require("net");

const upstreamHost = "localhost";
const upstreamPort = 9222;
const listenHost = "0.0.0.0";
const listenPort = 9223;

function rewriteJson(req, body) {
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch {
    return body;
  }

  const host = req.headers.host || "host.openshell.internal:9223";
  const rewrite = (value) => {
    if (typeof value !== "string") return value;
    return value
      .replace(/ws:\/\/(127\.0\.0\.1|0\.0\.0\.0|localhost):9222/g, `ws://${host}`)
      .replace(/http:\/\/(127\.0\.0\.1|0\.0\.0\.0|localhost):9222/g, `http://${host}`);
  };

  if (Array.isArray(parsed)) {
    for (const item of parsed) {
      if (item && typeof item === "object") {
        if ("webSocketDebuggerUrl" in item) item.webSocketDebuggerUrl = rewrite(item.webSocketDebuggerUrl);
        if ("devtoolsFrontendUrl" in item) item.devtoolsFrontendUrl = rewrite(item.devtoolsFrontendUrl);
      }
    }
  } else if (parsed && typeof parsed === "object") {
    if ("webSocketDebuggerUrl" in parsed) parsed.webSocketDebuggerUrl = rewrite(parsed.webSocketDebuggerUrl);
    if ("devtoolsFrontendUrl" in parsed) parsed.devtoolsFrontendUrl = rewrite(parsed.devtoolsFrontendUrl);
  }

  return JSON.stringify(parsed);
}

const server = http.createServer((req, res) => {
  const options = {
    host: upstreamHost,
    port: upstreamPort,
    method: req.method,
    path: req.url,
    headers: { ...req.headers, host: `${upstreamHost}:${upstreamPort}` },
  };

  const upstream = http.request(options, (upstreamRes) => {
    const chunks = [];
    upstreamRes.on("data", (chunk) => chunks.push(chunk));
    upstreamRes.on("end", () => {
      let body = Buffer.concat(chunks);
      const ctype = String(upstreamRes.headers["content-type"] || "");
      const isJson = ctype.includes("application/json") || String(req.url).startsWith("/json/");
      const headers = { ...upstreamRes.headers };

      if (isJson) {
        const rewritten = rewriteJson(req, body.toString("utf8"));
        body = Buffer.from(rewritten, "utf8");
        headers["content-length"] = String(body.length);
      }

      res.writeHead(upstreamRes.statusCode || 502, headers);
      res.end(body);
    });
  });

  upstream.on("error", (err) => {
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`proxy error: ${err.message}\n`);
  });

  req.pipe(upstream);
});

server.on("upgrade", (req, socket, head) => {
  const upstream = net.connect(upstreamPort, upstreamHost, () => {
    const lines = [`GET ${req.url} HTTP/1.1`];
    for (const [key, value] of Object.entries(req.headers)) {
      if (key.toLowerCase() === "host") {
        lines.push(`Host: ${upstreamHost}:${upstreamPort}`);
      } else {
        lines.push(`${key}: ${value}`);
      }
    }
    lines.push("", "");
    upstream.write(lines.join("\r\n"));
    if (head && head.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });

  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

server.listen(listenPort, listenHost, () => {
  console.log(`cdp proxy listening on ${listenHost}:${listenPort}`);
});
