let plugins = [];
let originalVisibility = new Map();
let selectedIds = new Set();
let lastSelectedIndex = null;
let searchText = "";
let visibilityFilter = "all";
let sortKey = "manufacturer";
let sortDirection = "asc";

const body = document.querySelector("#plugins-body");
const searchInput = document.querySelector("#search");
const saveButton = document.querySelector("#save");
const reloadButton = document.querySelector("#reload");
const showSelectedButton = document.querySelector("#show-selected");
const hideSelectedButton = document.querySelector("#hide-selected");
const countEl = document.querySelector("#count");
const visibleCountEl = document.querySelector("#visible-count");
const hiddenCountEl = document.querySelector("#hidden-count");
const dirtyStateEl = document.querySelector("#dirty-state");
const messageEl = document.querySelector("#message");

searchInput.addEventListener("input", () => {
  searchText = searchInput.value.trim().toLowerCase();
  render();
});

reloadButton.addEventListener("click", () => {
  if (isDirty() && !confirm("Discard unsaved visibility changes and reload from REAPER files?")) return;
  loadPlugins();
});

saveButton.addEventListener("click", saveChanges);
showSelectedButton.addEventListener("click", () => setVisibilityForSelected(true));
hideSelectedButton.addEventListener("click", () => setVisibilityForSelected(false));

document.querySelectorAll(".segment").forEach((button) => {
  button.addEventListener("click", () => {
    visibilityFilter = button.dataset.filter;
    document.querySelectorAll(".segment").forEach((segment) => segment.classList.toggle("active", segment === button));
    render();
  });
});

document.querySelectorAll("th[data-sort]").forEach((header) => {
  header.addEventListener("click", () => {
    const nextKey = header.dataset.sort;
    if (sortKey === nextKey) {
      sortDirection = sortDirection === "asc" ? "desc" : "asc";
    } else {
      sortKey = nextKey;
      sortDirection = "asc";
    }
    render();
  });
});

async function loadPlugins() {
  setMessage("Loading REAPER plugin files...");
  const response = await fetch("/api/plugins");
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || "Failed to load plugins.");

  plugins = payload.plugins;
  originalVisibility = new Map(plugins.map((plugin) => [plugin.id, plugin.isVisible]));
  selectedIds = new Set();
  lastSelectedIndex = null;
  setMessage(`Loaded ${plugins.length} plugins from ${payload.configDir}`);
  render();
}

async function saveChanges() {
  const changes = plugins
    .filter((plugin) => plugin.isVisible !== originalVisibility.get(plugin.id))
    .map((plugin) => ({ id: plugin.id, isVisible: plugin.isVisible }));

  if (changes.length === 0) return;

  setMessage("Saving changes...");
  saveButton.disabled = true;

  const response = await fetch("/api/save", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ changes })
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || "Failed to save changes.");

  plugins = payload.plugins;
  originalVisibility = new Map(plugins.map((plugin) => [plugin.id, plugin.isVisible]));
  selectedIds = new Set([...selectedIds].filter((id) => originalVisibility.has(id)));
  setMessage(payload.savedFiles.length ? `Saved ${payload.savedFiles.join(", ")}` : "No changes to save");
  render();
}

function visiblePlugins() {
  const filtered = plugins.filter((plugin) => {
    if (visibilityFilter === "visible" && !plugin.isVisible) return false;
    if (visibilityFilter === "hidden" && plugin.isVisible) return false;
    if (!searchText) return true;
    return [
      plugin.manufacturer,
      plugin.pluginType,
      plugin.name,
      plugin.sourceDisplayName
    ].join(" ").toLowerCase().includes(searchText);
  });

  return filtered.toSorted((a, b) => {
    const primary = compare(a[sortKey], b[sortKey]);
    const fallback = compare(a.name, b.name) || compare(a.manufacturer, b.manufacturer);
    const result = primary || fallback;
    return sortDirection === "asc" ? result : -result;
  });
}

function render() {
  const rows = visiblePlugins();
  body.replaceChildren();

  if (rows.length === 0) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.className = "empty";
    td.colSpan = 5;
    td.textContent = "No plugins match the current filters.";
    tr.append(td);
    body.append(tr);
  } else {
    rows.forEach((plugin, index) => body.append(pluginRow(plugin, index, rows)));
  }

  updateStatus(rows.length);
  updateSortHeaders();
}

function pluginRow(plugin, index, rows) {
  const tr = document.createElement("tr");
  tr.dataset.id = plugin.id;
  tr.classList.toggle("selected", selectedIds.has(plugin.id));

  tr.addEventListener("click", (event) => {
    if (event.target.matches("input")) return;
    updateSelection(plugin.id, index, rows, event);
    render();
  });

  const checkboxCell = document.createElement("td");
  checkboxCell.className = "check-column";
  const checkbox = document.createElement("input");
  checkbox.className = "visible-checkbox";
  checkbox.type = "checkbox";
  checkbox.checked = plugin.isVisible;
  checkbox.title = plugin.isVisible ? "Visible in REAPER" : "Hidden in REAPER";
  checkbox.addEventListener("click", (event) => {
    event.stopPropagation();
    const targetIds = selectedIds.has(plugin.id) ? selectedIds : new Set([plugin.id]);
    setVisibilityForIds(targetIds, checkbox.checked);
  });
  checkboxCell.append(checkbox);

  tr.append(
    checkboxCell,
    textCell(plugin.manufacturer),
    textCell(plugin.pluginType),
    textCell(plugin.name),
    textCell(plugin.sourceDisplayName)
  );

  return tr;
}

function textCell(text) {
  const td = document.createElement("td");
  td.textContent = text || "";
  td.title = text || "";
  return td;
}

function updateSelection(id, index, rows, event) {
  if (event.shiftKey && lastSelectedIndex !== null) {
    const start = Math.min(lastSelectedIndex, index);
    const end = Math.max(lastSelectedIndex, index);
    selectedIds = new Set(rows.slice(start, end + 1).map((plugin) => plugin.id));
  } else if (event.metaKey || event.ctrlKey) {
    if (selectedIds.has(id)) selectedIds.delete(id);
    else selectedIds.add(id);
    lastSelectedIndex = index;
  } else {
    selectedIds = new Set([id]);
    lastSelectedIndex = index;
  }
}

function setVisibilityForSelected(isVisible) {
  setVisibilityForIds(selectedIds, isVisible);
}

function setVisibilityForIds(ids, isVisible) {
  if (ids.size === 0) return;
  plugins = plugins.map((plugin) => ids.has(plugin.id) ? { ...plugin, isVisible } : plugin);
  render();
}

function updateStatus(shownCount) {
  const visibleCount = plugins.filter((plugin) => plugin.isVisible).length;
  const hiddenCount = plugins.length - visibleCount;
  const dirty = isDirty();

  countEl.textContent = `${shownCount} shown`;
  visibleCountEl.textContent = `${visibleCount} visible`;
  hiddenCountEl.textContent = `${hiddenCount} hidden`;
  dirtyStateEl.textContent = dirty ? "Unsaved changes" : "";
  saveButton.disabled = !dirty;
  showSelectedButton.disabled = selectedIds.size === 0;
  hideSelectedButton.disabled = selectedIds.size === 0;
}

function updateSortHeaders() {
  document.querySelectorAll("th[data-sort]").forEach((header) => {
    const isSorted = header.dataset.sort === sortKey;
    header.classList.toggle("sorted", isSorted);
    header.classList.toggle("desc", isSorted && sortDirection === "desc");
  });
}

function isDirty() {
  return plugins.some((plugin) => plugin.isVisible !== originalVisibility.get(plugin.id));
}

function compare(left, right) {
  return String(left || "").localeCompare(String(right || ""), undefined, { sensitivity: "base", numeric: true });
}

function setMessage(message) {
  messageEl.textContent = message;
}

window.addEventListener("error", (event) => {
  setMessage(event.error?.message || event.message || "Unexpected error.");
});

loadPlugins().catch((error) => setMessage(error.message));
