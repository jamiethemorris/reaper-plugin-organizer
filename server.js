import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "public");
const REAPER_CONFIG_DIR = join(homedir(), "Library", "Application Support", "REAPER");
const DEFAULT_PORT = Number(process.env.PORT || 48271);
const NO_OPEN = process.argv.includes("--no-open");

function main() {
  const port = getPort();
  startServer(port);
}

function startServer(port, attempt = 0) {
  const server = createServer(handleRequest);
  server.on("error", (error) => {
    if (error.code === "EADDRINUSE" && attempt < 20) {
      startServer(port + 1, attempt + 1);
      return;
    }
    console.error(error);
    process.exitCode = 1;
  });

  server.listen(port, "127.0.0.1", () => {
    const url = `http://127.0.0.1:${port}`;
    console.log(`REAPER Plugin Organizer running at ${url}`);
    if (!NO_OPEN) {
      spawn("open", [url], { detached: true, stdio: "ignore" }).unref();
    }
  });
}

function getPort() {
  const portArg = process.argv.find((arg) => arg.startsWith("--port="));
  return portArg ? Number(portArg.slice("--port=".length)) : DEFAULT_PORT;
}

async function handleRequest(request, response) {
  try {
    const url = new URL(request.url, `http://${request.headers.host}`);

    if (request.method === "GET" && url.pathname === "/api/plugins") {
      sendJson(response, { plugins: loadPlugins().map(publicPlugin), configDir: REAPER_CONFIG_DIR });
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/save") {
      const body = await readBody(request);
      const payload = JSON.parse(body || "{}");
      const result = savePlugins(Array.isArray(payload.changes) ? payload.changes : []);
      sendJson(response, result);
      return;
    }

    serveStatic(url.pathname, response);
  } catch (error) {
    sendJson(response, { error: error.message || String(error) }, 500);
  }
}

function serveStatic(pathname, response) {
  const requestedPath = pathname === "/" ? "/index.html" : pathname;
  const filePath = resolve(PUBLIC_DIR, `.${decodeURIComponent(requestedPath)}`);

  if (!filePath.startsWith(PUBLIC_DIR) || !existsSync(filePath)) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  const contentTypes = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8"
  };

  response.writeHead(200, { "content-type": contentTypes[extname(filePath)] || "application/octet-stream" });
  response.end(readFileSync(filePath));
}

function readBody(request) {
  return new Promise((resolveRead, rejectRead) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 8_000_000) {
        request.destroy();
        rejectRead(new Error("Request body is too large."));
      }
    });
    request.on("end", () => resolveRead(body));
    request.on("error", rejectRead);
  });
}

function sendJson(response, payload, status = 200) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(payload));
}

function loadPlugins() {
  if (!existsSync(REAPER_CONFIG_DIR)) {
    throw new Error(`Could not find the REAPER config folder at ${REAPER_CONFIG_DIR}`);
  }

  const filenames = readdirSync(REAPER_CONFIG_DIR).filter((filename) => filename.endsWith(".ini")).sort();
  const aliasMaps = loadVstAliasMaps(filenames);
  const plugins = [];

  for (const filename of filenames) {
    const filePath = join(REAPER_CONFIG_DIR, filename);
    if (isVstCache(filename)) {
      const aliasPath = vstAliasPath(filePath);
      plugins.push(...parseVstFile(filePath, aliasPath, aliasMaps.get(aliasPath) || new Map()));
    } else if (isAuCache(filename)) {
      plugins.push(...parseAuFile(filePath));
    } else if (isClapCache(filename)) {
      plugins.push(...parseClapFile(filePath));
    }
  }

  return plugins;
}

function savePlugins(changes) {
  const parsedPlugins = loadPlugins();
  const pluginsById = new Map(parsedPlugins.map((plugin) => [plugin.id, plugin]));
  const requestedChanges = changes
    .map((change) => ({ plugin: pluginsById.get(change.id), isVisible: Boolean(change.isVisible) }))
    .filter((change) => change.plugin && change.plugin.isVisible !== change.isVisible);

  if (requestedChanges.length === 0) {
    return { savedFiles: [], plugins: parsedPlugins.map(publicPlugin) };
  }

  const changedFiles = new Set();
  const changesBySource = groupBy(requestedChanges, (change) => change.plugin.sourceFile);

  for (const [sourceFile, fileChanges] of changesBySource) {
    const textFile = readTextFile(sourceFile);
    for (const { plugin, isVisible } of fileChanges) {
      const displayName = visibilityAdjustedName(plugin.visibleName, isVisible);
      if (plugin.format === "vst") {
        textFile.lines[plugin.lineIndex] = updateVstLine(textFile.lines[plugin.lineIndex], displayName);
      } else if (plugin.format === "au") {
        textFile.lines[plugin.lineIndex] = updateAuLine(textFile.lines[plugin.lineIndex], displayName);
      } else if (plugin.format === "clap") {
        textFile.lines[plugin.lineIndex] = updateClapLine(textFile.lines[plugin.lineIndex], displayName);
      }
    }
    writeTextFileWithBackup(textFile);
    changedFiles.add(sourceFile);
  }

  const vstAliasChanges = requestedChanges.filter((change) => change.plugin.format === "vst" && change.plugin.aliasFile);
  const aliasChangesByFile = groupBy(vstAliasChanges, (change) => change.plugin.aliasFile);

  for (const [aliasFile, fileChanges] of aliasChangesByFile) {
    const textFile = existsSync(aliasFile)
      ? readTextFile(aliasFile)
      : { filePath: aliasFile, lines: ["[vstaliasinfo]"], hadFinalNewline: true };
    const indexes = new Map();

    textFile.lines.forEach((line, index) => {
      const parts = splitKeyValue(line);
      if (parts) indexes.set(parts.key, index);
    });

    if (!textFile.lines.includes("[vstaliasinfo]")) {
      textFile.lines.unshift("[vstaliasinfo]");
    }

    for (const { plugin, isVisible } of fileChanges) {
      const displayName = visibilityAdjustedName(plugin.visibleName, isVisible);
      const line = `${plugin.key}=${displayName}`;
      if (indexes.has(plugin.key)) {
        textFile.lines[indexes.get(plugin.key)] = line;
      } else {
        textFile.lines.push(line);
      }
    }

    writeTextFileWithBackup(textFile);
    changedFiles.add(aliasFile);
  }

  const reloadedPlugins = loadPlugins();
  return {
    savedFiles: [...changedFiles].sort().map((filePath) => filePath.replace(`${REAPER_CONFIG_DIR}/`, "")),
    plugins: reloadedPlugins.map(publicPlugin)
  };
}

function parseVstFile(filePath, aliasFile, aliasMap) {
  const textFile = readTextFile(filePath);
  const plugins = [];

  textFile.lines.forEach((line, lineIndex) => {
    const parts = splitKeyValue(line);
    if (!parts || !(parts.key.endsWith(".vst") || parts.key.endsWith(".vst3"))) return;

    const displayName = aliasMap.get(parts.key) || vstDisplayName(parts.value);
    if (!displayName) return;

    const isVisible = !displayName.trimStart().startsWith("#");
    const visibleName = visibleDisplayName(displayName);
    const parsed = parseDisplayName(visibleName);
    const pluginType = vstType(parts.key, visibleName);

    plugins.push(makePlugin({
      sourceFile: filePath,
      lineIndex,
      format: "vst",
      key: parts.key,
      aliasFile,
      sourceDisplayName: basename(filePath),
      isVisible,
      visibleName,
      name: parsed.name,
      manufacturer: parsed.manufacturer,
      pluginType
    }));
  });

  return plugins;
}

function parseAuFile(filePath) {
  const textFile = readTextFile(filePath);
  const plugins = [];

  textFile.lines.forEach((line, lineIndex) => {
    const parts = splitKeyValue(line);
    if (!parts || !parts.key.includes(":")) return;

    const markerEnd = parts.value.indexOf(">");
    if (markerEnd === -1) return;

    const marker = parts.value.slice(0, markerEnd + 1);
    const displayPart = parts.value.slice(markerEnd + 1);
    const [manufacturerPart, ...nameParts] = parts.key.split(":");
    const fallbackManufacturer = manufacturerPart.trim() || "Unknown";
    const fallbackName = nameParts.join(":").trim() || parts.key;
    const displayName = displayPart || `${fallbackName} (${fallbackManufacturer})`;
    const isVisible = !displayName.trimStart().startsWith("#");
    const visibleName = visibleDisplayName(displayName);
    const parsed = parseDisplayName(visibleName, fallbackManufacturer);

    plugins.push(makePlugin({
      sourceFile: filePath,
      lineIndex,
      format: "au",
      key: parts.key,
      aliasFile: null,
      sourceDisplayName: basename(filePath),
      isVisible,
      visibleName,
      name: parsed.name || fallbackName,
      manufacturer: parsed.manufacturer,
      pluginType: marker === "<inst>" ? "AU Instrument" : "AU"
    }));
  });

  return plugins;
}

function parseClapFile(filePath) {
  const textFile = readTextFile(filePath);
  const plugins = [];
  let section = "";

  textFile.lines.forEach((line, lineIndex) => {
    if (line.startsWith("[") && line.endsWith("]")) {
      section = line.slice(1, -1);
      return;
    }

    const parts = splitKeyValue(line);
    if (!parts || parts.key === "_") return;

    const pipeIndex = parts.value.indexOf("|");
    if (pipeIndex === -1) return;

    const instrumentFlag = parts.value.slice(0, pipeIndex);
    const displayName = parts.value.slice(pipeIndex + 1);
    const isVisible = !displayName.trimStart().startsWith("#");
    const visibleName = visibleDisplayName(displayName);
    const parsed = parseDisplayName(visibleName);

    plugins.push(makePlugin({
      sourceFile: filePath,
      lineIndex,
      format: "clap",
      key: parts.key,
      aliasFile: null,
      sourceDisplayName: basename(filePath),
      isVisible,
      visibleName,
      name: parsed.name || section.replace(/\.clap$/i, ""),
      manufacturer: parsed.manufacturer,
      pluginType: instrumentFlag === "1" ? "CLAP Instrument" : "CLAP"
    }));
  });

  return plugins;
}

function makePlugin(plugin) {
  return {
    id: stableId(plugin.sourceFile, plugin.lineIndex, plugin.key),
    ...plugin
  };
}

function publicPlugin(plugin) {
  return {
    id: plugin.id,
    name: plugin.name,
    manufacturer: plugin.manufacturer,
    pluginType: plugin.pluginType,
    sourceDisplayName: plugin.sourceDisplayName,
    isVisible: plugin.isVisible
  };
}

function loadVstAliasMaps(filenames) {
  const maps = new Map();

  for (const filename of filenames) {
    if (!filename.startsWith("reaper-vstrenames") || !filename.endsWith(".ini")) continue;

    const filePath = join(REAPER_CONFIG_DIR, filename);
    const textFile = readTextFile(filePath);
    const map = new Map();

    for (const line of textFile.lines) {
      const parts = splitKeyValue(line);
      if (!parts || !(parts.key.endsWith(".vst") || parts.key.endsWith(".vst3"))) continue;
      map.set(parts.key, parts.value);
    }

    maps.set(filePath, map);
  }

  return maps;
}

function isVstCache(filename) {
  return filename.startsWith("reaper-vstplugins") && filename.endsWith(".ini");
}

function isAuCache(filename) {
  return filename.startsWith("reaper-auplugins") && filename.endsWith(".ini");
}

function isClapCache(filename) {
  return filename.startsWith("reaper-clap") && filename.endsWith(".ini");
}

function vstAliasPath(cachePath) {
  return join(dirname(cachePath), basename(cachePath).replace("reaper-vstplugins", "reaper-vstrenames"));
}

function vstDisplayName(value) {
  const firstComma = value.indexOf(",");
  if (firstComma === -1) return "";
  const secondComma = value.indexOf(",", firstComma + 1);
  if (secondComma === -1) return "";
  return value.slice(secondComma + 1);
}

function updateVstLine(line, displayName) {
  const equalsIndex = line.indexOf("=");
  if (equalsIndex === -1) return line;

  const firstComma = line.indexOf(",", equalsIndex + 1);
  if (firstComma === -1) return line;
  const secondComma = line.indexOf(",", firstComma + 1);
  if (secondComma === -1) return line;

  return `${line.slice(0, secondComma + 1)}${displayName}`;
}

function updateAuLine(line, displayName) {
  const markerEnd = line.indexOf(">");
  return markerEnd === -1 ? line : `${line.slice(0, markerEnd + 1)}${displayName}`;
}

function updateClapLine(line, displayName) {
  const pipeIndex = line.indexOf("|");
  return pipeIndex === -1 ? line : `${line.slice(0, pipeIndex + 1)}${displayName}`;
}

function visibilityAdjustedName(visibleName, isVisible) {
  const cleanName = visibleDisplayName(visibleName);
  return isVisible ? cleanName : `#${cleanName}`;
}

function visibleDisplayName(displayName) {
  const trimmed = String(displayName || "").trim();
  return trimmed.startsWith("#") ? trimmed.slice(1).trimStart() : trimmed;
}

function vstType(key, displayName) {
  const isInstrument = displayName.includes("!!!VSTi");
  if (key.endsWith(".vst3")) return isInstrument ? "VST3 Instrument" : "VST3";
  return isInstrument ? "VST Instrument" : "VST";
}

function parseDisplayName(displayName, fallbackManufacturer = "Unknown") {
  const cleaned = visibleDisplayName(displayName).replaceAll("!!!VSTi", "").trim();
  const matches = [...cleaned.matchAll(/\(([^()]*)\)/g)];
  const ignored = [
    /x86_64/i,
    /^\d+\s*(out|ch)$/i,
    /^\d+\s*->\s*\d+\s*ch$/i,
    /mono/i,
    /stereo/i,
    /surround/i
  ];
  let manufacturer = fallbackManufacturer;

  for (const match of matches.toReversed()) {
    const candidate = match[1].trim();
    if (candidate && !ignored.some((pattern) => pattern.test(candidate))) {
      manufacturer = candidate;
      break;
    }
  }

  const name = matches.length
    ? cleaned.slice(0, matches.at(-1).index).trim()
    : cleaned;

  return {
    name,
    manufacturer: manufacturer || "Unknown"
  };
}

function splitKeyValue(line) {
  if (!line || line.startsWith("[")) return null;
  const equalsIndex = line.indexOf("=");
  if (equalsIndex === -1) return null;
  const key = line.slice(0, equalsIndex);
  if (!key) return null;
  return { key, value: line.slice(equalsIndex + 1) };
}

function readTextFile(filePath) {
  const text = readFileSync(filePath, "utf8").replaceAll("\r\n", "\n").replaceAll("\r", "\n");
  const hadFinalNewline = text.endsWith("\n");
  const lines = text.split("\n");
  if (hadFinalNewline) lines.pop();
  return { filePath, lines, hadFinalNewline };
}

function writeTextFileWithBackup(textFile) {
  if (existsSync(textFile.filePath)) {
    copyFileSync(textFile.filePath, `${textFile.filePath}.bak-${timestamp()}`);
  } else {
    mkdirSync(dirname(textFile.filePath), { recursive: true });
  }

  const content = `${textFile.lines.join("\n")}${textFile.hadFinalNewline ? "\n" : ""}`;
  writeFileSync(textFile.filePath, content, "utf8");
}

function groupBy(items, getKey) {
  const groups = new Map();
  for (const item of items) {
    const key = getKey(item);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  return groups;
}

function stableId(...parts) {
  return createHash("sha1").update(parts.join("\u001f")).digest("base64url");
}

function timestamp() {
  const date = new Date();
  const pad = (value) => String(value).padStart(2, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    "-",
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds())
  ].join("");
}

function basename(filePath) {
  return filePath.split("/").at(-1);
}

main();
