-- @description REAPER Plugin Organizer
-- @version 1.2.0
-- @about Dockable VST, VST3, AU and CLAP visibility manager for macOS.
-- @requires ReaImGui 0.10+, SWS Extension

local r = reaper
local directory = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]')
local Catalog = dofile(directory .. '/lib/catalog.lua')
local Model = dofile(directory .. '/lib/model.lua')
local Theme = dofile(directory .. '/lib/theme.lua')
local theme = Theme.new(r)
local function message(text) r.ShowMessageBox(tostring(text), 'Plugin Organizer', 0) end

if not r.ImGui_GetBuiltinPath or not r.BR_Win32_WritePrivateProfileString then
  message('Install ReaImGui 0.10 or newer and the SWS Extension, then restart REAPER.')
  return
end
local ok, ImGui = pcall(function()
  return dofile(r.ImGui_GetBuiltinPath() .. '/imgui.lua')('0.10')
end)
if not ok then message(ImGui) return end

local loaded, catalog = pcall(Catalog.load, r.GetResourcePath(), r.GetOS())
if not loaded then message(catalog) return end
local model = Model.new(catalog.rows)
local ctx = ImGui.CreateContext('REAPER Plugin Organizer', ImGui.ConfigFlags_NavEnableKeyboard)
local clipper = ImGui.CreateListClipper(ctx)
ImGui.Attach(ctx, clipper)
local font = ImGui.CreateFont('sans-serif')
ImGui.Attach(ctx, font)
local status = 'Ready'
local restart_needed, next_dock = false, nil
local _, _, section, command = r.get_action_context()
if command and command > 0 then
  r.SetToggleCommandState(section, command, 1)
  r.RefreshToolbar2(section, command)
end
r.atexit(function()
  if command and command > 0 then
    r.SetToggleCommandState(section, command, 0)
    r.RefreshToolbar2(section, command)
  end
end)

local function save()
  local success, result = pcall(Catalog.save, catalog, r)
  if not success then message(result) return false end
  if result.files > 0 then
    local selected = model.selected
    local sort, query, visibility, format = model.sort, model.query, model.visibility, model.format
    local reloaded, replacement = pcall(Catalog.load, r.GetResourcePath(), r.GetOS())
    if not reloaded then message('Saved, but reload failed: ' .. tostring(replacement)) return false end
    catalog, model = replacement, Model.new(replacement.rows)
    model.selected, model.sort, model.query, model.visibility, model.format = selected, sort, query, visibility, format
    restart_needed = true
    status = 'Saved. Restart REAPER to refresh the FX browser.'
  end
  return true
end

local function may_discard()
  local _, _, changed = model:counts()
  if changed == 0 then return true end
  local choice = r.ShowMessageBox('Save visibility changes before continuing?', 'Plugin Organizer', 3)
  if choice == 6 then return save() end
  return choice == 7
end

local function reload()
  if not may_discard() then return end
  local success, replacement = pcall(Catalog.load, r.GetResourcePath(), r.GetOS())
  if not success then message(replacement) return end
  local sort = model.sort
  catalog, model = replacement, Model.new(replacement.rows)
  model.sort = sort
  status = restart_needed and 'Restart REAPER to refresh the FX browser.' or 'Reloaded'
end

local function plugin_tooltip(row)
  if not ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_DelayNormal) then return end
  local colors = theme:push_colors(ImGui, ctx)
  if not ImGui.BeginTooltip(ctx) then ImGui.PopStyleColor(ctx, colors) return end
  ImGui.PushTextWrapPos(ctx, 520)
  ImGui.Text(ctx, row.name)
  ImGui.TextDisabled(ctx, row.manufacturer .. ' | ' .. row.plugin_type .. ' | '
    .. (row.visible and 'Visible' or 'Hidden'))
  ImGui.Separator(ctx)
  local matches, formats = model.matches:summary(row)
  ImGui.Text(ctx, ('Likely matches in plugin cache: %d'):format(#matches))
  for _, format in ipairs(Model.formats) do
    local counts = formats[format]
    local detail = counts.visible + counts.hidden == 0 and 'no other match found'
      or ('%d visible, %d hidden'):format(counts.visible, counts.hidden)
    ImGui.Text(ctx, format .. ': ' .. detail)
  end
  if #matches > 0 then
    ImGui.Separator(ctx)
    for i = 1, math.min(#matches, 10) do
      local candidate = matches[i]
      ImGui.Text(ctx, ('%s | %s | %s'):format(candidate.plugin_type, candidate.name,
        candidate.visible and 'Visible' or 'Hidden'))
    end
    if #matches > 10 then ImGui.TextDisabled(ctx, ('+%d more matches'):format(#matches - 10)) end
  end
  ImGui.Separator(ctx)
  ImGui.TextDisabled(ctx, row.key .. '\n' .. row.file)
  ImGui.PopTextWrapPos(ctx)
  ImGui.EndTooltip(ctx)
  ImGui.PopStyleColor(ctx, colors)
end

local function format_visibility(format, visible)
  local count = model:set_format_visible(format, visible)
  status = ('%s %d %s plugins. Changes are unsaved.'):format(
    visible and 'Checked' or 'Unchecked', count, format)
end

local function select(row)
  local mods = ImGui.GetKeyMods(ctx)
  model:select(row.id, (mods & ImGui.Mod_Ctrl) ~= 0, (mods & ImGui.Mod_Shift) ~= 0)
end

local function menu()
  if not ImGui.BeginMenuBar(ctx) then return end
  if ImGui.BeginMenu(ctx, 'File') then
    if ImGui.MenuItem(ctx, 'Reload plugin list') then reload() end
    if ImGui.MenuItem(ctx, 'Open backups folder') then
      local path = r.GetResourcePath() .. '/PluginOrganizerBackups'
      r.RecursiveCreateDirectory(path, 0)
      r.CF_ShellExecute(path)
    end
    ImGui.EndMenu(ctx)
  end
  if ImGui.BeginMenu(ctx, 'Format') then
    for _, format in ipairs(Model.formats) do
      local visible, hidden = model:format_counts(format)
      if ImGui.BeginMenu(ctx, format .. ' (' .. (visible + hidden) .. ')', visible + hidden > 0) then
        if ImGui.MenuItem(ctx, 'Uncheck all ' .. format .. ' (' .. visible .. ')', nil, false, visible > 0) then
          format_visibility(format, false)
        end
        if ImGui.MenuItem(ctx, 'Check all ' .. format .. ' (' .. hidden .. ')', nil, false, hidden > 0) then
          format_visibility(format, true)
        end
        ImGui.EndMenu(ctx)
      end
    end
    ImGui.EndMenu(ctx)
  end
  if ImGui.BeginMenu(ctx, 'View') then
    if ImGui.MenuItem(ctx, 'Follow REAPER theme', nil, theme.enabled) then
      theme:set_enabled(not theme.enabled)
    end
    local docked = ImGui.GetWindowDockID(ctx) ~= 0
    if ImGui.MenuItem(ctx, 'Dock window', nil, docked) then next_dock = docked and 0 or -1 end
    ImGui.EndMenu(ctx)
  end
  ImGui.EndMenuBar(ctx)
end

local function toolbar()
  local width = ImGui.GetContentRegionAvail(ctx)
  if ImGui.IsWindowAppearing(ctx) or ((ImGui.GetKeyMods(ctx) & ImGui.Mod_Ctrl) ~= 0
      and ImGui.IsKeyPressed(ctx, ImGui.Key_F, false)) then
    ImGui.SetKeyboardFocusHere(ctx)
  end
  ImGui.SetNextItemWidth(ctx, math.max(180, width - 306))
  local edited, query = ImGui.InputTextWithHint(ctx, '##search', 'Search plugins or manufacturers', model.query)
  if edited then model.query, model.dirty = query, true end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 140)
  local filtered, format = ImGui.Combo(ctx, '##format', model.format, 'All formats\0VST\0VST3\0AU\0CLAP\0')
  if filtered then model.format, model.dirty = format, true end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 140)
  local visibility_changed, visibility = ImGui.Combo(ctx, '##visibility', model.visibility, 'All plugins\0Visible\0Hidden\0')
  if visibility_changed then model.visibility, model.dirty = visibility, true end
  model:view()
  local _, _, changed, selected = model:counts()
  local toolbar_x = ImGui.GetCursorScreenPos(ctx)

  ImGui.BeginDisabled(ctx, selected == 0)
  if ImGui.Button(ctx, 'Show selected') then model:set_visible(true) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Hide selected') then model:set_visible(false) end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not model.undo)
  if ImGui.Button(ctx, 'Undo') then model:undo_edit() end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, changed == 0)
  if ImGui.Button(ctx, 'Save changes') then save() end
  ImGui.EndDisabled(ctx)
  local summary = ('%d selected   %d unsaved'):format(selected, changed)
  local used = ImGui.GetItemRectMax(ctx)
  local edge = toolbar_x + width
  if edge - used >= ImGui.CalcTextSize(ctx, summary) + 12 then ImGui.SameLine(ctx) end
  ImGui.TextDisabled(ctx, summary)

  if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then
    local mods = ImGui.GetKeyMods(ctx)
    if (mods & ImGui.Mod_Ctrl) ~= 0 then
      if ImGui.IsKeyPressed(ctx, ImGui.Key_S, false) and changed > 0 then save() end
      if not ImGui.IsAnyItemActive(ctx) then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_A, false) then model:select_all() end
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Z, false) then model:undo_edit() end
      end
    elseif not ImGui.IsAnyItemActive(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then
      local first
      for _, row in ipairs(model:view()) do if model.selected[row.id] then first = row break end end
      if first then model:set_visible(not first.visible) end
    end
  end
end

local function plugin_table()
  local _, height = ImGui.GetContentRegionAvail(ctx)
  local flags = ImGui.TableFlags_Sortable | ImGui.TableFlags_SortMulti | ImGui.TableFlags_Resizable
    | ImGui.TableFlags_Reorderable | ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV
    | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
  local colors = theme:push_list(ImGui, ctx)
  if not ImGui.BeginTable(ctx, 'Plugins', 4, flags, 0, math.max(80, height - 44)) then
    ImGui.PopStyleColor(ctx, colors)
    return
  end
  ImGui.TableSetupColumn(ctx, 'Visible', ImGui.TableColumnFlags_WidthFixed | ImGui.TableColumnFlags_NoSort, 58)
  ImGui.TableSetupColumn(ctx, 'Name', ImGui.TableColumnFlags_WidthStretch, 3)
  ImGui.TableSetupColumn(ctx, 'Manufacturer', ImGui.TableColumnFlags_WidthStretch | ImGui.TableColumnFlags_DefaultSort, 2)
  ImGui.TableSetupColumn(ctx, 'Type', ImGui.TableColumnFlags_WidthFixed, 70)
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableHeadersRow(ctx)
  if ImGui.TableNeedSort(ctx) then
    model.sort = {}
    local index, columns = 0, {[1] = 'name', [2] = 'manufacturer', [3] = 'plugin_type'}
    while true do
      local has, column, _, direction = ImGui.TableGetColumnSortSpecs(ctx, index)
      if not has then break end
      if columns[column] then
        model.sort[#model.sort + 1] = { key = columns[column], descending = direction == ImGui.SortDirection_Descending }
      end
      index = index + 1
    end
    model.dirty = true
  end
  local rows = model:view()
  ImGui.ListClipper_Begin(clipper, #rows)
  while ImGui.ListClipper_Step(clipper) do
    local first, last = ImGui.ListClipper_GetDisplayRange(clipper)
    for i = first + 1, last do
      local row = rows[i]
      ImGui.PushID(ctx, row.id)
      local selected_colors = model.selected[row.id] and theme:push_selected(ImGui, ctx) or 0
      ImGui.TableNextRow(ctx, 0, 22)
      if model.selected[row.id] then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, ImGui.GetColor(ctx, ImGui.Col_Header))
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg1, 0)
      end
      ImGui.TableSetColumnIndex(ctx, 0)
      local toggled, value = ImGui.Checkbox(ctx, '##visible', row.visible)
      if toggled then model:set_visible(value, row.id) end
      plugin_tooltip(row)
      for column, key in ipairs({'name', 'manufacturer', 'plugin_type'}) do
        ImGui.TableSetColumnIndex(ctx, column)
        if ImGui.Selectable(ctx, row[key] .. '##' .. key, model.selected[row.id] or false) then select(row) end
        plugin_tooltip(row)
      end
      ImGui.PopStyleColor(ctx, selected_colors)
      ImGui.PopID(ctx)
    end
  end
  ImGui.EndTable(ctx)
  ImGui.PopStyleColor(ctx, colors)
end

local function frame()
  local style = theme:push(ImGui, ctx)
  ImGui.SetNextWindowSize(ctx, 940, 660, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 700, 360, 10000, 10000)
  if next_dock then ImGui.SetNextWindowDockID(ctx, next_dock) next_dock = nil end
  ImGui.PushFont(ctx, font, 13)
  local shown, open = ImGui.Begin(ctx, 'Plugin Organizer', true, ImGui.WindowFlags_MenuBar)
  if shown then
    menu()
    toolbar()
    plugin_table()
    local visible, hidden = model:counts()
    ImGui.TextDisabled(ctx, ('%d plugins   %d shown   %d visible   %d hidden'):format(#model.rows, #model:view(), visible, hidden))
    ImGui.TextDisabled(ctx, status)
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)
  Theme.pop(ImGui, ctx, style)
  if not open and not may_discard() then open = true end
  return open
end

local function loop()
  local success, continue = xpcall(frame, debug.traceback)
  if not success then message(continue) return end
  if continue then r.defer(loop) end
end
r.defer(loop)
