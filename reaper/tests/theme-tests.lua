local directory = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]')
local Theme = dofile(directory .. '/../lib/theme.lua')

return function(test, eq)
  local function fake_api(source, preference)
    local api = {reads=0, saved={}}
    api.GetExtState = function() return preference or '' end
    api.SetExtState = function(section, key, value, persist)
      api.saved = {section=section, key=key, value=value, persist=persist}
    end
    api.GetThemeColor = function(key, flags)
      eq(flags, 0)
      api.reads = api.reads + 1
      return source[key] or -1
    end
    -- Simulate Windows' channel order to catch native-color conversion mistakes.
    api.ColorFromNative = function(c) return c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff end
    api.time_precise = function() return 0 end
    return api
  end

  test('theme preserves readable light and dark theme colors and selection text', function()
    for _, source in ipairs({
      {col_main_bg=0x303030ff, col_main_text=0xe0e0e0ff, genlist_bg=0x202020ff,
        genlist_fg=0xddddddff, genlist_selbg=0x24566aff, genlist_selfg=0xffffffff},
      {col_main_bg=0xeeeeeeff, col_main_text=0x222222ff, genlist_bg=0xffffffff,
        genlist_fg=0x111111ff, genlist_selbg=0x234a6bff, genlist_selfg=0xffffffff},
    }) do
      local p = Theme.palette(source)
      eq(p.colors.WindowBg, source.col_main_bg)
      eq(p.colors.Text, source.col_main_text)
      eq(p.colors.ChildBg, source.genlist_bg)
      eq(p.list.Text, source.genlist_fg)
      eq(p.selected.Header, source.genlist_selbg)
      eq(p.selected.Text, source.genlist_selfg)
    end
  end)

  test('theme repairs low contrast text across fields, buttons and selections', function()
    for _, shade in ipairs({0x000000ff, 0x777777ff, 0xffffffff}) do
      local p = Theme.palette({col_main_bg=shade, col_main_text=shade, genlist_bg=shade,
        genlist_fg=shade, genlist_selbg=shade, genlist_selfg=shade, col_main_editbk=shade,
        col_buttonbg=shade, col_toolbar_text_on=shade})
      for _, key in ipairs({'WindowBg', 'PopupBg', 'FrameBg', 'FrameBgHovered', 'FrameBgActive',
        'Button', 'ButtonHovered', 'ButtonActive', 'Header', 'HeaderHovered', 'HeaderActive'}) do
        assert(Theme.contrast(p.colors.Text, p.colors[key]) >= 4.5, key)
      end
      assert(Theme.contrast(p.colors.TextDisabled, p.colors.WindowBg) >= 4.5)
      assert(Theme.contrast(p.list.Text, p.colors.TableRowBgAlt) >= 4.5)
      assert(Theme.contrast(p.selected.Text, p.selected.Header) >= 4.5)
      assert(Theme.contrast(p.selected.Text, p.selected.HeaderHovered) >= 4.5)
      assert(Theme.contrast(p.colors.CheckMark, p.colors.FrameBg) >= 3)
      assert(Theme.contrast(p.colors.ScrollbarGrab, p.colors.ScrollbarBg) >= 3)
    end
  end)

  test('theme handles native channels, signed color flags, black and unavailable values', function()
    local api = fake_api({col_main_bg=0x00332211, genlist_bg=0,
      col_buttonbg=0x80404040 - 0x100000000})
    local theme = Theme.new(api)
    eq(theme.enabled, true)
    eq(theme:refresh(0), true)
    eq(theme.current.colors.WindowBg, 0x112233ff)
    eq(theme.current.colors.ChildBg, 0x000000ff)
    eq(theme.current.colors.Button, 0x404040ff)
    assert(Theme.contrast(theme.current.list.Text, theme.current.colors.ChildBg) >= 4.5)
    eq(Theme.palette({}).colors.WindowBg, 0x303030ff)
  end)

  test('theme polling detects live color edits without rebuilding unchanged palettes', function()
    local source = {col_main_bg=0x00303030}
    local api = fake_api(source)
    local theme = Theme.new(api)
    theme:refresh(0)
    local before, reads = theme.current, api.reads
    eq(theme:refresh(0.5), false)
    eq(api.reads, reads)
    eq(theme:refresh(1), false)
    eq(theme.current, before)
    source.col_main_bg = 0x00eeeeee
    eq(theme:refresh(2), true)
    eq(theme.current.colors.WindowBg, 0xeeeeeeff)
    assert(theme.current ~= before)
  end)

  test('theme follow preference persists and disabled mode performs no color reads', function()
    local api = fake_api({}, '0')
    local theme = Theme.new(api)
    eq(theme.enabled, false)
    eq(theme:refresh(0), false)
    eq(api.reads, 0)
    theme:set_enabled(true)
    eq(api.saved.value, '1')
    eq(api.saved.persist, true)
    eq(api.saved.key, 'follow_theme')
    eq(theme:refresh(0), true)
    theme:set_enabled(false)
    eq(api.saved.value, '0')
  end)

  test('theme style scopes balance even when follow is toggled during a frame', function()
    local colors, vars = 0, 0
    local gui = setmetatable({}, {__index=function(_, key) return key end})
    gui.PushStyleColor = function(_, key, value)
      assert(key:match('^Col_') and math.type(value) == 'integer')
      colors = colors + 1
    end
    gui.PushStyleVar = function() vars = vars + 1 end
    gui.PopStyleColor = function(_, count) colors = colors - count assert(colors >= 0) end
    gui.PopStyleVar = function(_, count) vars = vars - count assert(vars >= 0) end
    local theme = Theme.new(fake_api({}))
    local scope = theme:push(gui, {})
    local list = theme:push_list(gui, {})
    local selected = theme:push_selected(gui, {})
    local tooltip = theme:push_colors(gui, {})
    gui.PopStyleColor({}, tooltip + selected + list)
    theme:set_enabled(false)
    Theme.pop(gui, {}, scope)
    eq(colors, 0)
    eq(vars, 0)
    scope = theme:push(gui, {})
    eq(colors, 0)
    eq(theme:push_list(gui, {}), 0)
    eq(theme:push_selected(gui, {}), 0)
    Theme.pop(gui, {}, scope)
    eq(vars, 0)
  end)

  if reaper then
    test('active REAPER theme can be read without changing its settings', function()
      local api = setmetatable({GetExtState=function() return '' end}, {__index=reaper})
      local theme = Theme.new(api)
      eq(theme:refresh(0), true)
      local native = reaper.GetThemeColor('col_main_bg', 0)
      if native ~= -1 then
        local r, g, b = reaper.ColorFromNative(native & 0xffffff)
        eq(theme.current.colors.WindowBg, (r << 24) | (g << 16) | (b << 8) | 0xff)
      end
    end)
  end
end
