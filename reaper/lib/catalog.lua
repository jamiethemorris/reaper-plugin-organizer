local M = {}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

function M.read(path)
  local f, err, code = io.open(path, 'rb')
  if not f then
    if code == 2 then return nil end
    error(err)
  end
  local data = assert(f:read('*a'))
  assert(f:close())
  return data
end

function M.write(path, data)
  local f = assert(io.open(path, 'wb'))
  local ok, err = f:write(data)
  local closed, close_err = f:close()
  assert(ok, err)
  assert(closed, close_err)
end

function M.ini(data)
  local entries, sections, section = {}, {}, nil
  for line in ((data or '') .. '\n'):gmatch('(.-)\n') do
    line = line:gsub('\r$', '')
    local header = line:match('^%[([^%]]+)%]%s*$')
    if header then
      section = header
      sections[section] = sections[section] or {}
    elseif section and not line:match('^%s*[;#]') then
      local key, value = line:match('^([^=]+)=(.*)$')
      if key then
        local entry = { section = section, key = key, value = value }
        entries[#entries + 1] = entry
        local previous = sections[section][key]
        entry.duplicate = previous ~= nil
        if previous then previous.duplicate = true end
        sections[section][key] = entry
      end
    end
  end
  return { entries = entries, sections = sections }
end

function M.entry(doc, section, key)
  local s = doc.sections[section]
  return s and s[key]
end

function M.unhide(name)
  return (name:gsub('^%s*#+%s*', ''))
end

function M.is_visible(name) return not name:match('^%s*#') end

local function metadata(text)
  text = trim(M.unhide(text):gsub('!!!VSTi', ''))
  local candidates = {}
  for start, content, finish in text:gmatch('()%(([^()]*)%)()') do
    local c = trim(content):lower()
    local ignore = c == 'mono' or c == 'stereo' or c == 'surround'
      or c == 'x86' or c == 'x86_64' or c == 'x64' or c == 'arm64' or c == 'aarch64'
      or c == '32 bit' or c == '64 bit' or c == '32-bit' or c == '64-bit'
      or c:match('^%d+%s*out$') or c:match('^%d+%s*ch$')
      or c:match('^%d+%s*%->%s*%d+%s*ch$')
    if not ignore then candidates[#candidates + 1] = {start, trim(content), finish} end
  end
  local vendor = candidates[#candidates]
  if not vendor then return text, 'Unknown' end
  local name = trim(text:sub(1, vendor[1] - 1) .. text:sub(vendor[3]))
  return name, vendor[2]
end
M.metadata = metadata

function M.filenames(os_name, exists)
  if os_name == 'macOS-arm64' then
    return 'reaper-vstplugins_arm64.ini', 'reaper-auplugins_arm64.ini',
      'reaper-clap-macos-aarch64.ini'
  elseif os_name == 'OSX64' or os_name == 'macOS-x86_64' then
    local au = exists('reaper-auplugins64.ini') and 'reaper-auplugins64.ini' or 'reaper-auplugins.ini'
    return 'reaper-vstplugins64.ini', au, 'reaper-clap-macos-x86_64.ini'
  end
  error('This version supports 64-bit macOS REAPER. Detected: ' .. os_name)
end

function M.load(root, os_name)
  local vst, au, clap = M.filenames(os_name, function(n) return M.read(root .. '/' .. n) ~= nil end)
  local aliases = vst:gsub('vstplugins', 'vstrenames')
  local files, documents, rows = {}, {}, {}
  for _, filename in ipairs({vst, au, clap, aliases}) do
    local raw = M.read(root .. '/' .. filename)
    files[filename] = raw or false
    documents[filename] = M.ini(raw)
  end

  local function add(filename, e, format, prefix, display, fallback, instrument, alias, original_name)
    if e.duplicate or (alias and alias.duplicate) or display == '' then return end
    local name, manufacturer = metadata(display)
    if fallback then manufacturer = fallback end
    local row = {
      id = filename .. '\31' .. e.section .. '\31' .. e.key,
      file = filename, section = e.section, key = e.key, value = e.value,
      format = format, prefix = prefix, display = display,
      name = name, manufacturer = manufacturer,
      match_names = {original_name or name},
      plugin_type = format .. (instrument and 'i' or ''),
      visible = M.is_visible(display), original_visible = M.is_visible(display),
      alias_file = format:match('^VST') and aliases or nil,
      alias_value = alias and alias.value or nil,
    }
    row.search = (name .. ' ' .. manufacturer .. ' ' .. row.plugin_type):lower()
    rows[#rows + 1] = row
    return row
  end

  for _, e in ipairs(documents[vst].entries) do
    local base = e.key:match('^([^<]+)'):lower()
    if e.section == 'vstcache' and (base:match('%.vst$') or base:match('%.vst3$')) then
      local prefix, display = e.value:match('^([^,]*,[^,]*,)(.+)$')
      if display then
        local alias = M.entry(documents[aliases], 'vstaliasinfo', e.key)
        local original_name, vendor = metadata(display)
        local effective = alias and alias.value ~= '' and alias.value or display
        local row = add(vst, e, base:match('%.vst3$') and 'VST3' or 'VST', prefix, effective,
          vendor, effective:find('!!!VSTi', 1, true) ~= nil, alias, original_name)
        -- Shell entries share a filename; it cannot identify their individual FX.
        if row and not e.key:find('<', 1, true) then
          row.match_names[#row.match_names + 1] = e.key:gsub('%.vst3?$', '')
        end
      end
    end
  end
  for _, e in ipairs(documents[au].entries) do
    if e.section == 'auplugins' then
      local marker, display = e.value:match('^(<[^>]+>)(.*)$')
      if marker == '<inst>' or marker == '<!inst>' then
        local vendor, fallback = e.key:match('^([^:]+):%s*(.*)$')
        if display == '' then display = fallback and (fallback .. ' (' .. trim(vendor) .. ')') or e.key end
        local original_name = fallback and fallback:gsub('<%d+$', '')
        add(au, e, 'AU', marker, display, vendor and trim(vendor), marker == '<inst>', nil, original_name)
      end
    end
  end
  for _, e in ipairs(documents[clap].entries) do
    if e.key ~= '_' then
      local flags, display = e.value:match('^(%d+)|(.+)$')
      if flags then add(clap, e, 'CLAP', flags .. '|', display, nil, (tonumber(flags) & 1) ~= 0) end
    end
  end
  return { root = root, rows = rows, files = files }
end

function M.changes(catalog)
  local edits = {}
  for _, row in ipairs(catalog.rows) do
    if row.visible ~= row.original_visible then
      local display = row.visible and M.unhide(row.display) or ('#' .. row.display)
      edits[#edits + 1] = { file = row.file, section = row.section, key = row.key,
        expected = row.value, value = row.prefix .. display }
      if row.alias_file then
        edits[#edits + 1] = { file = row.alias_file, section = 'vstaliasinfo', key = row.key,
          expected = row.alias_value, value = display }
      end
    end
  end
  return edits
end

-- Use REAPER's profile API to keep SWELL's cached INI data coherent with disk.
-- Preflight every entry and create all backups before the first write.
function M.save(catalog, api)
  local edits = M.changes(catalog)
  if #edits == 0 then return { files = 0 } end
  local originals, docs, names = {}, {}, {}
  for _, edit in ipairs(edits) do
    if not docs[edit.file] then
      originals[edit.file] = M.read(catalog.root .. '/' .. edit.file) or false
      docs[edit.file] = M.ini(originals[edit.file] or nil)
      names[#names + 1] = edit.file
    end
    local entry = M.entry(docs[edit.file], edit.section, edit.key)
    if (entry and entry.duplicate) or (entry and entry.value or nil) ~= edit.expected then
      error(edit.file .. ' changed since loading. Reload the list before saving.')
    end
    local sentinel = '\1missing\1'
    local _, current = api.BR_Win32_GetPrivateProfileString(edit.section, edit.key, sentinel,
      catalog.root .. '/' .. edit.file)
    if (current ~= sentinel and current or nil) ~= edit.expected then
      error('REAPER has a newer cached value for ' .. edit.key .. '. Reload or restart before saving.')
    end
  end
  table.sort(names)
  local backup_root = catalog.root .. '/PluginOrganizerBackups'
  api.RecursiveCreateDirectory(backup_root, 0)
  local backup = backup_root .. '/' .. os.date('%Y%m%d-%H%M%S') .. '-' .. math.floor(api.time_precise() * 1000000)
  api.RecursiveCreateDirectory(backup, 0)
  local manifest = {}
  for _, name in ipairs(names) do
    if originals[name] then M.write(backup .. '/' .. name, originals[name]) end
    manifest[#manifest + 1] = (originals[name] and 'restore ' or 'originally absent ') .. name
  end
  M.write(backup .. '/manifest.txt', table.concat(manifest, '\n') .. '\n')
  local applied = {}
  local ok, err = pcall(function()
    for _, edit in ipairs(edits) do
      applied[#applied + 1] = edit
      assert(api.BR_Win32_WritePrivateProfileString(edit.section, edit.key, edit.value,
        catalog.root .. '/' .. edit.file), 'Unable to write ' .. edit.file)
    end
    for _, name in ipairs(names) do docs[name] = M.ini(M.read(catalog.root .. '/' .. name)) end
    for _, edit in ipairs(edits) do
      local actual = M.entry(docs[edit.file], edit.section, edit.key)
      assert(actual and actual.value == edit.value, 'Write verification failed: ' .. edit.file)
    end
  end)
  if not ok then
    local rollback_ok = true
    for i = #applied, 1, -1 do
      local e = applied[i]
      local restored, result = pcall(api.BR_Win32_WritePrivateProfileString,
        e.section, e.key, e.expected or '', catalog.root .. '/' .. e.file)
      if not restored or not result then rollback_ok = false end
    end
    error(tostring(err) .. '\n' .. (rollback_ok and 'Changed entries were rolled back.' or 'Some entries could not be rolled back.')
      .. '\nOriginal files: ' .. backup)
  end
  return { files = #names, backup = backup }
end

return M
