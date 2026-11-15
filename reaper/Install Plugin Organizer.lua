-- @description Install REAPER Plugin Organizer
-- Run once to copy the scripts into REAPER's resource folder and register the action.
local source = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]')
local destination = reaper.GetResourcePath() .. '/Scripts/REAPER Plugin Organizer'
local files = {'REAPER Plugin Organizer.lua', 'lib/catalog.lua', 'lib/matches.lua', 'lib/model.lua', 'lib/theme.lua'}
local function install()
  reaper.RecursiveCreateDirectory(destination .. '/lib', 0)
  for _, name in ipairs(files) do
    local input = assert(io.open(source .. '/' .. name, 'rb'))
    local data = assert(input:read('*a'))
    input:close()
    local output = assert(io.open(destination .. '/' .. name, 'wb'))
    assert(output:write(data))
    assert(output:close())
  end
  local command = reaper.AddRemoveReaScript(true, 0, destination .. '/REAPER Plugin Organizer.lua', true)
  assert(command > 0, 'Could not register the action.')
  if reaper.GetToggleCommandStateEx(0, command) == 1 then
    reaper.ShowMessageBox('Updated. Save any pending changes, then close and reopen the organizer to load the new version.',
      'Plugin Organizer installation', 0)
  else
    reaper.Main_OnCommand(command, 0)
  end
end
local ok, err = pcall(install)
if not ok then reaper.ShowMessageBox(tostring(err), 'Plugin Organizer installation', 0) end
