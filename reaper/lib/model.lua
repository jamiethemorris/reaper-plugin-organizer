local M = {}
M.__index = M
local directory = debug.getinfo(1, 'S').source:sub(2):match('^(.*)[/\\]')
local Matches = dofile(directory .. '/matches.lua')
M.formats = Matches.formats

function M.new(rows)
  return setmetatable({ rows = rows, selected = {}, anchor = nil, query = '', visibility = 0,
    format = 0, sort = {{key = 'manufacturer', descending = false}}, dirty = true,
    matches = Matches.new(rows) }, M)
end

function M:view()
  if not self.dirty then return self.filtered end
  local rows = {}
  for _, row in ipairs(self.rows) do
    local matches = (self.visibility == 0 or (self.visibility == 1) == row.visible)
      and (self.format == 0 or row.format == M.formats[self.format])
    for word in self.query:lower():gmatch('%S+') do
      if not row.search:find(word, 1, true) then matches = false break end
    end
    if matches then rows[#rows + 1] = row end
  end
  table.sort(rows, function(a, b)
    for _, spec in ipairs(self.sort) do
      local left, right = tostring(a[spec.key]):lower(), tostring(b[spec.key]):lower()
      if left ~= right then
        if spec.descending then return left > right end
        return left < right
      end
    end
    if a.name ~= b.name then return a.name:lower() < b.name:lower() end
    return a.id < b.id
  end)
  -- Selection follows the current view; hidden selections never get bulk edits.
  local in_view = {}
  for _, row in ipairs(rows) do in_view[row.id] = true end
  for id in pairs(self.selected) do if not in_view[id] then self.selected[id] = nil end end
  if self.anchor and not in_view[self.anchor] then self.anchor = nil end
  self.filtered, self.dirty = rows, false
  return rows
end

function M:select(id, additive, range)
  local view, anchor_index, target_index = self:view()
  for i, row in ipairs(view) do
    if row.id == self.anchor then anchor_index = i end
    if row.id == id then target_index = i end
  end
  if range and anchor_index and target_index then
    if not additive then self.selected = {} end
    for i = math.min(anchor_index, target_index), math.max(anchor_index, target_index) do
      self.selected[view[i].id] = true
    end
  elseif additive then
    self.selected[id] = not self.selected[id] or nil
    self.anchor = id
  else
    self.selected, self.anchor = {[id] = true}, id
  end
end

function M:select_all()
  for _, row in ipairs(self:view()) do self.selected[row.id] = true end
end

local function apply_visibility(self, value, includes)
  local before = {}
  local count = 0
  for _, row in ipairs(self.rows) do
    if includes(row) and row.visible ~= value then
      before[row.id] = row.visible
      row.visible = value
      count = count + 1
    end
  end
  if next(before) then self.undo, self.dirty = before, true end
  return count
end

function M:set_visible(value, clicked)
  local targets = clicked and not self.selected[clicked] and {[clicked] = true} or self.selected
  return apply_visibility(self, value, function(row) return targets[row.id] end)
end

function M:format_counts(format)
  local visible, hidden = 0, 0
  for _, row in ipairs(self.rows) do
    if row.format == format then
      if row.visible then visible = visible + 1 else hidden = hidden + 1 end
    end
  end
  return visible, hidden
end

function M:set_format_visible(format, value)
  local index
  for i, name in ipairs(M.formats) do if name == format then index = i break end end
  assert(index, 'Unknown plugin format: ' .. tostring(format))
  local count = apply_visibility(self, value, function(row) return row.format == format end)
  self.format, self.visibility, self.query = index, 0, ''
  self.selected, self.anchor, self.dirty = {}, nil, true
  return count
end

function M:undo_edit()
  if not self.undo then return end
  for _, row in ipairs(self.rows) do
    if self.undo[row.id] ~= nil then row.visible = self.undo[row.id] end
  end
  self.undo, self.dirty = nil, true
end

function M:counts()
  local visible, changed, selected = 0, 0, 0
  for _, row in ipairs(self.rows) do
    if row.visible then visible = visible + 1 end
    if row.visible ~= row.original_visible then changed = changed + 1 end
    if self.selected[row.id] then selected = selected + 1 end
  end
  return visible, #self.rows - visible, changed, selected
end

return M
