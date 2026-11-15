local base = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]') .. '/../..'
local Catalog = dofile(base .. '/reaper/lib/catalog.lua')
local Model = dofile(base .. '/reaper/lib/model.lua')
local Matches = dofile(base .. '/reaper/lib/matches.lua')
local output, failures = {}, 0
local function eq(actual, expected)
  assert(actual == expected, ('Expected %q, got %q'):format(tostring(expected), tostring(actual)))
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  output[#output + 1] = (ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ('\n' .. err))
  if not ok then failures = failures + 1 end
end
dofile(base .. '/reaper/tests/theme-tests.lua')(test, eq)
local sequence = 0
local function mkdir(path)
  if reaper then reaper.RecursiveCreateDirectory(path, 0)
  else assert(os.execute('mkdir -p ' .. "'" .. path:gsub("'", "'\\''") .. "'")) end
end
local function fixture()
  sequence = sequence + 1
  local root = base .. '/build/test-' .. os.date('%Y%m%d%H%M%S') .. '-' .. sequence
  mkdir(root)
  Catalog.write(root .. '/reaper-vstplugins_arm64.ini', table.concat({
    '[vstcache]',
    'Comp.vst3=HASH,100{ABC,Compressor (Acme, Inc.) (2->6ch)',
    'Shell.vst3<101=HASH,101{ABC,# Synth (Acme, Inc.) (18 out)!!!VSTi',
    'Failed.vst=HASH',
    '[unrelated]',
    'Comp.vst3=do not touch', ''}, '\r\n'))
  Catalog.write(root .. '/reaper-vstrenames_arm64.ini', '[other]\nkeep=untouched\n[vstaliasinfo]\nComp.vst3=My Custom Compressor\n')
  Catalog.write(root .. '/reaper-auplugins_arm64.ini', '[auplugins]\nVendor: EQ=<!inst>\nVendor: Piano=<inst>#Piano (Vendor)\nBus=<!inst>\n')
  Catalog.write(root .. '/reaper-clap-macos-aarch64.ini', '[Bundle.clap]\n_=HASH\nid=3|#Keys (Maker)\n[Other.clap]\n_=HASH2\nid=0|Echo (Maker)\n')
  Catalog.write(root .. '/reaper-vstplugins64.ini', '[vstcache]\nLegacy.vst=H,1,Legacy (Old)\n')
  return Catalog.load(root, 'macOS-arm64')
end
local function find(c, key, section)
  for _, row in ipairs(c.rows) do if row.key == key and (not section or row.section == section) then return row end end
  error('Missing fixture row ' .. key)
end

test('active architecture, aliases, shells, AU and CLAP flags', function()
  local c = fixture()
  eq(#c.rows, 7)
  eq(find(c, 'Comp.vst3').name, 'My Custom Compressor')
  eq(find(c, 'Comp.vst3').manufacturer, 'Acme, Inc.')
  eq(find(c, 'Shell.vst3<101').plugin_type, 'VST3i')
  eq(find(c, 'Shell.vst3<101').visible, false)
  eq(find(c, 'Vendor: Piano').plugin_type, 'AUi')
  eq(find(c, 'id', 'Bundle.clap').plugin_type, 'CLAPi')
  assert(find(c, 'id', 'Bundle.clap').id ~= find(c, 'id', 'Other.clap').id)
end)
test('manufacturer ignores routing and architecture while keeping name variants', function()
  local name, vendor = Catalog.metadata('Synth (x86_64) (Acme, Inc.) (2->6ch)!!!VSTi')
  eq(vendor, 'Acme, Inc.')
  assert(name:find('(2->6ch)', 1, true))
  eq(select(2, Catalog.metadata('Product (Stereo Works)')), 'Stereo Works')
  eq(Catalog.unhide('## Name'), 'Name')
end)
test('toggle back to original produces no file changes', function()
  local c = fixture()
  local row = find(c, 'Shell.vst3<101')
  row.visible = true
  eq(#Catalog.changes(c), 2)
  eq(Catalog.changes(c)[1].value, 'HASH,101{ABC,Synth (Acme, Inc.) (18 out)!!!VSTi')
  row.visible = false
  eq(#Catalog.changes(c), 0)
end)
test('range selection uses IDs after sorting; checkbox edits the selection', function()
  local m = Model.new(fixture().rows)
  local view = m:view()
  m:select(view[1].id, false, false)
  m:select(view[3].id, false, true)
  eq(select(4, m:counts()), 3)
  m:set_visible(false, view[1].id)
  for i = 1, 3 do eq(view[i].visible, false) end
  m:undo_edit()
  eq(select(3, m:counts()), 0)
  m.sort, m.dirty = {{key='name', descending=true}}, true
  m:select(m:view()[#m:view()].id, false, true)
  assert(select(4, m:counts()) >= 1)
end)
test('filtering removes out-of-view selections before bulk changes', function()
  local m = Model.new(fixture().rows)
  m:select_all()
  m.query, m.dirty = 'Custom Compressor', true
  eq(#m:view(), 1)
  eq(select(4, m:counts()), 1)
  m:set_visible(false)
  eq(select(3, m:counts()), 1)
end)
test('unknown sections, malformed records and duplicate keys stay uneditable', function()
  local c = fixture()
  Catalog.write(c.root .. '/reaper-vstplugins_arm64.ini', '[vstcache]\nBad.vst3=H,1,One\nBad.vst3=H,2,Two\n[other]\nWrong.vst3=H,1,Wrong\n')
  eq(#Catalog.load(c.root, 'macOS-arm64').rows, 5)
end)

local function plugin(id, name, manufacturer, format, visible)
  return {id=id, name=name, manufacturer=manufacturer, format=format, plugin_type=format,
    visible=visible, original_visible=visible, search=(name .. ' ' .. manufacturer .. ' ' .. format):lower()}
end

test('duplicate normalization covers architecture, channels and manufacturer prefixes', function()
  for _, name in ipairs({'FabFilter Pro-Q', 'Pro-Q (x86_64)', '# Pro-Q_x86_64',
    'Pro-Q x64', 'Pro-Q [arm64]', 'Pro-Q (Mono)', 'Pro-Q (2->6ch)',
    'Pro-Q (18 out)!!!VSTi', 'Pro-Q (64-bit)', 'Pro-Q (Stereo) x86_64'}) do
    eq(Matches.name_key(name, 'FabFilter'), 'pro q')
  end
  eq(Matches.name_key('X86 Synth', 'Maker'), 'x86 synth')
  eq(select(2, Catalog.metadata('Keys (Maker) (x64)')), 'Maker')
end)

test('duplicate summary sees all formats, hidden entries and pending visibility changes', function()
  local rows = {
    plugin('au', 'Pro-Q', 'FabFilter', 'AU', true),
    plugin('vst', 'FabFilter Pro-Q (x86_64)', 'FabFilter', 'VST', false),
    plugin('vst3', 'Pro-Q (Stereo)', 'FabFilter', 'VST3', true),
    plugin('clap', 'Pro-Q', 'FabFilter', 'CLAP', false),
  }
  local m = Model.new(rows)
  m.format, m.query, m.visibility = 3, 'Pro-Q', 1
  eq(#m:view(), 1)
  local found, counts = m.matches:summary(rows[1])
  eq(#found, 3)
  eq(counts.VST.hidden, 1)
  eq(counts.VST3.visible, 1)
  eq(counts.CLAP.hidden, 1)
  eq(counts.AU.visible, 0)
  m:set_visible(true, 'vst')
  local _, updated = m.matches:summary(rows[1])
  eq(updated.VST.visible, 1)
  eq(updated.VST.hidden, 0)
  m:undo_edit()
  eq(select(2, m.matches:summary(rows[1])).VST.hidden, 1)
end)

test('matching keeps versions, FX variants and different manufacturers distinct', function()
  local rows = {
    plugin('base', 'Synth 2', 'Maker, Inc.', 'AU', true),
    plugin('same', 'Maker Synth 2', 'Maker', 'VST3', true),
    plugin('v1', 'Synth', 'Maker', 'VST', true),
    plugin('v3', 'Synth 3', 'Maker', 'VST3', true),
    plugin('fx', 'Synth 2 FX', 'Maker', 'VST', true),
    plugin('different', 'Synth 2', 'Another Maker', 'VST', true),
    plugin('unknown1', 'Synth 2', 'Unknown', 'VST', true),
    plugin('unknown2', 'Synth 2', 'Unknown', 'AU', true),
  }
  local index = Matches.new(rows)
  eq(#index:find(rows[1]), 1)
  eq(index:find(rows[1])[1].id, 'same')
  eq(#index:find(rows[7]), 0)
end)

test('matching retains cached identity across custom names without grouping shell products', function()
  local c = fixture()
  -- A renamed AU keeps its original product identity in the cache key.
  Catalog.write(c.root .. '/reaper-auplugins_arm64.ini', '[auplugins]\nAcme: Compressor=<!inst>#Favorite (Acme)\nAcme: Different=<!inst>My Custom Compressor (Acme)\n')
  Catalog.write(c.root .. '/reaper-vstplugins_arm64.ini', Catalog.read(c.root .. '/reaper-vstplugins_arm64.ini')
    .. '[vstcache]\nShell.vst3<102=HASH,102{ABC,Other Synth (Acme, Inc.)!!!VSTi\n')
  c = Catalog.load(c.root, 'macOS-arm64')
  local index = Matches.new(c.rows)
  local found = index:find(find(c, 'Comp.vst3'))
  eq(#found, 1)
  eq(found[1].key, 'Acme: Compressor')
  eq(found[1].visible, false)
  eq(#index:find(find(c, 'Shell.vst3<101')), 0)
end)

test('format-wide uncheck ignores filters and includes instruments, with one-step undo', function()
  local c = fixture()
  local m = Model.new(c.rows)
  m.query, m.format, m.visibility = 'Custom Compressor', 2, 1
  m:select_all()
  eq(#m:view(), 1)
  eq(m:set_format_visible('AU', false), 2)
  eq(m.query, '')
  eq(m.visibility, 0)
  eq(m.format, 3)
  eq(#m:view(), 3)
  eq(select(4, m:counts()), 0)
  eq(m:format_counts('AU'), 0)
  eq(select(2, m:format_counts('AU')), 3)
  eq(find(c, 'Vendor: Piano').visible, false)
  eq(find(c, 'Comp.vst3').visible, true)
  eq(select(3, m:counts()), 2)
  m:undo_edit()
  eq(select(3, m:counts()), 0)
  eq(find(c, 'Vendor: Piano').visible, false)
  eq(m:format_counts('AU'), 2)
  eq(m:set_format_visible('AU', true), 1)
  eq(m:format_counts('AU'), 3)
  m:undo_edit()
  eq(find(c, 'Vendor: Piano').visible, false)
end)

test('format uncheck permits selective rechecking and rejects invalid formats', function()
  local c = fixture()
  local m = Model.new(c.rows)
  m:set_format_visible('AU', false)
  m:set_visible(true, find(c, 'Vendor: EQ').id)
  eq(m:format_counts('AU'), 1)
  eq(find(c, 'Vendor: Piano').visible, false)
  eq(find(c, 'Bus').visible, false)
  eq(pcall(m.set_format_visible, m, 'AUi', true), false)
  eq(m:format_counts('AU'), 1)
end)

if reaper and reaper.BR_Win32_WritePrivateProfileString then
  test('format-wide native save touches only the chosen format', function()
    local c = fixture()
    local m = Model.new(c.rows)
    m:set_format_visible('AU', false)
    m:set_visible(true, find(c, 'Vendor: EQ').id)
    local vst = Catalog.read(c.root .. '/reaper-vstplugins_arm64.ini')
    local saved = Catalog.save(c, reaper)
    eq(saved.files, 1)
    eq(Catalog.read(c.root .. '/reaper-vstplugins_arm64.ini'), vst)
    local fresh = Catalog.load(c.root, 'macOS-arm64')
    eq(find(fresh, 'Vendor: EQ').visible, true)
    eq(find(fresh, 'Vendor: Piano').visible, false)
    eq(find(fresh, 'Bus').visible, false)
  end)
  test('real SWS save round trip preserves aliases, sections, markers and backups', function()
    local c = fixture()
    local old = Catalog.read(c.root .. '/reaper-vstplugins_arm64.ini')
    for _, row in ipairs(c.rows) do row.visible = not row.visible end
    local saved = Catalog.save(c, reaper)
    eq(saved.files, 4)
    eq(Catalog.read(saved.backup .. '/reaper-vstplugins_arm64.ini'), old)
    local fresh = Catalog.load(c.root, 'macOS-arm64')
    local expected = {}
    for _, row in ipairs(c.rows) do expected[row.id] = row.visible end
    for _, row in ipairs(fresh.rows) do eq(row.visible, expected[row.id]) end
    eq(find(fresh, 'Comp.vst3').display, '#My Custom Compressor')
    local alias = Catalog.ini(Catalog.read(c.root .. '/reaper-vstrenames_arm64.ini'))
    eq(Catalog.entry(alias, 'other', 'keep').value, 'untouched')
    for _, row in ipairs(fresh.rows) do row.visible = not row.visible end
    Catalog.save(fresh, reaper)
    local restored = Catalog.load(c.root, 'macOS-arm64')
    eq(find(restored, 'Comp.vst3').display, 'My Custom Compressor')
    eq(find(restored, 'Vendor: EQ').prefix, '<!inst>')
    eq(find(restored, 'id', 'Bundle.clap').prefix, '3|')
  end)
  test('no-op saves create no backup or write operations', function()
    eq(Catalog.save(fixture(), {}).files, 0)
  end)
  test('concurrent rename aborts all writes', function()
    local c = fixture()
    find(c, 'Comp.vst3').visible = false
    assert(reaper.BR_Win32_WritePrivateProfileString('vstaliasinfo', 'Comp.vst3', 'New name', c.root .. '/reaper-vstrenames_arm64.ini'))
    local before = Catalog.read(c.root .. '/reaper-vstplugins_arm64.ini')
    local ok = pcall(Catalog.save, c, reaper)
    eq(ok, false)
    eq(Catalog.read(c.root .. '/reaper-vstplugins_arm64.ini'), before)
  end)
  test('mid-save failure rolls back entries using the same profile API', function()
    local c = fixture()
    find(c, 'Comp.vst3').visible = false
    local calls, api = 0, setmetatable({}, {__index = reaper})
    api.BR_Win32_WritePrivateProfileString = function(...)
      calls = calls + 1
      if calls == 2 then return false end
      return reaper.BR_Win32_WritePrivateProfileString(...)
    end
    local ok = pcall(Catalog.save, c, api)
    eq(ok, false)
    local fresh = Catalog.load(c.root, 'macOS-arm64')
    eq(find(fresh, 'Comp.vst3').visible, true)
    eq(find(fresh, 'Comp.vst3').display, 'My Custom Compressor')
    eq(find(fresh, 'Comp.vst3').value, find(c, 'Comp.vst3').value)
  end)
else
  output[#output + 1] = 'SKIP native SWS save tests: run this file inside REAPER.'
end
output[#output + 1] = ('%d failure(s)'):format(failures)
local report = table.concat(output, '\n') .. '\n'
if reaper then
  Catalog.write(base .. '/build/reaper-test-results.txt', report)
else
  io.write(report)
  os.exit(failures == 0 and 0 or 1)
end
