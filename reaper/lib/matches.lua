local M = {}
M.__index = M
M.formats = {'VST', 'VST3', 'AU', 'CLAP'}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

local function words(s)
  return trim(s:lower():gsub('[%p%s]+', ' '))
end

local company_suffixes = {inc=true, incorporated=true, ltd=true, limited=true,
  llc=true, gmbh=true, corp=true, corporation=true}
local function vendor_key(s)
  s = words(s)
  while company_suffixes[s:match('(%S+)$')] do s = trim(s:gsub('%S+$', '')) end
  return s
end

local architecture = {x86=true, x86_64=true, x64=true, arm64=true, aarch64=true,
  ['32 bit']=true, ['64 bit']=true, ['32-bit']=true, ['64-bit']=true}
local function variant(s)
  s = trim(s:lower())
  return architecture[s] or s == 'mono' or s == 'stereo' or s == 'surround'
    or s:match('^%d+%s*out$') or s:match('^%d+%s*ch$')
    or s:match('^%d+%s*%->%s*%d+%s*ch$')
end

function M.name_key(name, manufacturer)
  name = name:lower():gsub('^%s*#+%s*', ''):gsub('!!!vsti', '')
  name = name:gsub('%(([^()]*)%)', function(s) return variant(s) and ' ' or ('(' .. s .. ')') end)
  name = name:gsub('%[([^%[%]]*)%]', function(s) return variant(s) and ' ' or ('[' .. s .. ']') end)
  -- Bare architecture labels are removed only at the end, on a token boundary.
  local changed = true
  while changed do
    changed, name = false, trim(name)
    for suffix in pairs(architecture) do
      if name:sub(-#suffix) == suffix then
        local prefix = name:sub(1, -#suffix - 1)
        if prefix:match('[%s_%-]$') then
          name, changed = prefix:gsub('[%s_%-]+$', ''), true
          break
        end
      end
    end
  end
  name = words(name)
  local vendor = vendor_key(manufacturer)
  if vendor ~= '' and vendor ~= 'unknown' and name:sub(1, #vendor + 1) == vendor .. ' ' then
    name = name:sub(#vendor + 2)
  end
  return name
end

function M.new(rows)
  local self = setmetatable({index = {}, keys = {}, related = {}}, M)
  for _, row in ipairs(rows) do
    local vendor, keys = vendor_key(row.manufacturer), {}
    -- An unknown maker cannot establish a reliable cross-format identity.
    if vendor ~= '' and vendor ~= 'unknown' then
      for _, name in ipairs(row.match_names or {row.name}) do
        local normalized = M.name_key(name, row.manufacturer)
        local key = vendor .. '\31' .. normalized
        if normalized ~= '' and not keys[key] then
          keys[key] = true
          self.index[key] = self.index[key] or {}
          self.index[key][#self.index[key] + 1] = row
        end
      end
    end
    self.keys[row.id] = keys
  end
  return self
end

function M:find(row)
  if self.related[row.id] then return self.related[row.id] end
  local found, seen = {}, {[row.id] = true}
  for key in pairs(self.keys[row.id] or {}) do
    for _, candidate in ipairs(self.index[key]) do
      if not seen[candidate.id] then
        found[#found + 1], seen[candidate.id] = candidate, true
      end
    end
  end
  table.sort(found, function(a, b)
    if a.format ~= b.format then return a.format < b.format end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  self.related[row.id] = found
  return found
end

function M:summary(row)
  local matches, formats = self:find(row), {}
  for _, format in ipairs(M.formats) do formats[format] = {visible=0, hidden=0} end
  for _, candidate in ipairs(matches) do
    local counts = formats[candidate.format]
    local state = candidate.visible and 'visible' or 'hidden'
    counts[state] = counts[state] + 1
  end
  return matches, formats
end

return M
