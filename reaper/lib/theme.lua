local M = {}
M.__index = M

local keys = {'col_main_bg', 'col_main_bg2', 'col_main_text', 'col_main_text2',
  'col_main_editbk', 'col_main_3dsh', 'col_buttonbg', 'col_toolbar_text_on',
  'genlist_bg', 'genlist_fg', 'genlist_grid', 'genlist_selbg', 'genlist_selfg'}

local function rgba(r, g, b) return (r << 24) | (g << 16) | (b << 8) | 0xff end
local function channels(c) return (c >> 24) & 0xff, (c >> 16) & 0xff, (c >> 8) & 0xff end
local function alpha(c, a) return (c & 0xffffff00) | math.floor(a * 255 + 0.5) end
local function mix(a, b, amount)
  local ar, ag, ab = channels(a)
  local br, bg, bb = channels(b)
  local function blend(x, y) return math.floor(x + (y - x) * amount + 0.5) end
  return rgba(blend(ar, br), blend(ag, bg), blend(ab, bb))
end

local function luminance(c)
  local function linear(v)
    v = v / 255
    return v <= 0.04045 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = channels(c)
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
end

function M.contrast(a, b)
  local x, y = luminance(a), luminance(b)
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
end

local function readable(foreground, background, minimum)
  minimum = minimum or 4.5
  if M.contrast(foreground, background) >= minimum then return foreground end
  local target = M.contrast(0xffffffff, background) > M.contrast(0x000000ff, background)
    and 0xffffffff or 0x000000ff
  for step = 1, 20 do
    local candidate = mix(foreground, target, step / 20)
    if M.contrast(candidate, background) >= minimum then return candidate end
  end
  return target
end

function M.palette(source)
  local bg = source.col_main_bg or source.col_main_bg2 or 0x303030ff
  local text = readable(source.col_main_text or source.col_main_text2 or 0xddddddff, bg)
  local list = source.genlist_bg or bg
  local list_text = readable(source.genlist_fg or text, list)
  local selection = source.genlist_selbg or mix(list, list_text, 0.25)
  local selection_text = readable(source.genlist_selfg or list_text, selection)
  local accent = source.col_toolbar_text_on or selection
  local edit = readable(source.col_main_editbk or list, text)
  local button = readable(source.col_buttonbg or mix(bg, text, 0.07), text)
  local border = readable(source.col_main_3dsh or mix(bg, text, 0.25), edit, 2)
  local function surface(base, amount) return readable(mix(base, accent, amount), text) end
  local function list_surface(amount) return readable(mix(list, list_text, amount), list_text) end
  local colors = {
    Text=text, TextDisabled=readable(mix(bg, text, 0.65), bg),
    WindowBg=bg, ChildBg=list, PopupBg=bg, Border=border, BorderShadow=0,
    FrameBg=edit, FrameBgHovered=surface(edit, 0.10), FrameBgActive=surface(edit, 0.18),
    Button=button, ButtonHovered=surface(button, 0.12), ButtonActive=surface(button, 0.22),
    TitleBg=bg, TitleBgActive=surface(bg, 0.04), TitleBgCollapsed=bg, MenuBarBg=bg,
    Header=surface(bg, 0.18), HeaderHovered=surface(bg, 0.26), HeaderActive=surface(bg, 0.34),
    CheckMark=readable(accent, edit, 3), SliderGrab=readable(accent, edit, 3),
    SliderGrabActive=readable(accent, edit, 4.5),
    ScrollbarBg=bg, ScrollbarGrab=readable(mix(bg, text, 0.4), bg, 3),
    ScrollbarGrabHovered=readable(mix(bg, text, 0.6), bg, 3), ScrollbarGrabActive=text,
    Separator=mix(bg, text, 0.20), SeparatorHovered=readable(accent, bg, 3),
    SeparatorActive=readable(accent, bg, 3),
    ResizeGrip=alpha(text, 0.18), ResizeGripHovered=alpha(text, 0.4), ResizeGripActive=alpha(text, 0.65),
    TableHeaderBg=list_surface(0.07), TableBorderStrong=source.genlist_grid or border,
    TableBorderLight=source.genlist_grid or mix(list, list_text, 0.12),
    TableRowBg=list, TableRowBgAlt=list_surface(0.025),
    TextSelectedBg=surface(edit, 0.3), NavCursor=readable(accent, bg, 3),
    NavWindowingHighlight=alpha(text, 0.65), NavWindowingDimBg=alpha(bg, 0.6),
    ModalWindowDimBg=alpha(bg, 0.65), DockingPreview=alpha(selection, 0.7),
    DockingEmptyBg=bg, Tab=button, TabHovered=surface(button, 0.12),
    TabSelected=surface(button, 0.18), TabSelectedOverline=readable(accent, button, 3),
    TabDimmed=bg, TabDimmedSelected=button, TabDimmedSelectedOverline=border,
  }
  -- The list and selected rows have their own text colors in REAPER themes.
  return {colors=colors, list={
    Text=list_text, TextDisabled=readable(mix(list, list_text, 0.65), list),
    Header=selection, HeaderHovered=list_surface(0.10), HeaderActive=list_surface(0.16),
  }, selected={
    Text=selection_text, Header=selection,
    HeaderHovered=readable(mix(selection, selection_text, 0.08), selection_text),
    HeaderActive=readable(mix(selection, selection_text, 0.14), selection_text),
  }}
end

function M.new(api)
  return setmetatable({api=api, enabled=api.GetExtState('REAPER Plugin Organizer', 'follow_theme') ~= '0',
    next_refresh=0}, M)
end

function M:set_enabled(enabled)
  self.enabled, self.next_refresh = enabled, 0
  self.api.SetExtState('REAPER Plugin Organizer', 'follow_theme', enabled and '1' or '0', true)
end

function M:refresh(now)
  if not self.enabled or now < self.next_refresh then return false end
  self.next_refresh = now + 1
  local source, signature = {}, {}
  for _, key in ipairs(keys) do
    local native = self.api.GetThemeColor(key, 0)
    signature[#signature + 1] = tostring(native)
    -- Some valid theme colors carry signed flags. Only -1 means unavailable.
    if native and native ~= -1 then
      source[key] = rgba(self.api.ColorFromNative(native & 0xffffff))
    end
  end
  local fingerprint = table.concat(signature, ',')
  if fingerprint == self.fingerprint then return false end
  self.fingerprint, self.current = fingerprint, M.palette(source)
  return true
end

local function push_colors(ImGui, ctx, colors)
  local count = 0
  for name, value in pairs(colors or {}) do
    ImGui.PushStyleColor(ctx, ImGui['Col_' .. name], value)
    count = count + 1
  end
  return count
end

function M:push_colors(ImGui, ctx)
  return push_colors(ImGui, ctx, self.enabled and self.current and self.current.colors)
end

function M:push_list(ImGui, ctx)
  return push_colors(ImGui, ctx, self.enabled and self.current and self.current.list)
end

function M:push_selected(ImGui, ctx)
  return push_colors(ImGui, ctx, self.enabled and self.current and self.current.selected)
end

local spacing = {
  {'WindowPadding', 8, 8}, {'FramePadding', 6, 3}, {'ItemSpacing', 6, 4},
  {'ItemInnerSpacing', 5, 4}, {'CellPadding', 6, 2}, {'ScrollbarSize', 13},
  {'WindowRounding', 0}, {'ChildRounding', 0}, {'FrameRounding', 2},
  {'PopupRounding', 2}, {'ScrollbarRounding', 2}, {'GrabRounding', 1},
  {'WindowBorderSize', 1}, {'PopupBorderSize', 1}, {'FrameBorderSize', 1},
  {'DisabledAlpha', 0.65},
}

function M:push(ImGui, ctx)
  self:refresh(self.api.time_precise())
  for _, spec in ipairs(spacing) do
    ImGui.PushStyleVar(ctx, ImGui['StyleVar_' .. spec[1]], spec[2], spec[3])
  end
  return {colors=self:push_colors(ImGui, ctx), vars=#spacing}
end

function M.pop(ImGui, ctx, scope)
  ImGui.PopStyleColor(ctx, scope.colors)
  ImGui.PopStyleVar(ctx, scope.vars)
end

return M
