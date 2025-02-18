local opts = require('grug-far/opts')
local utils = require('grug-far/utils')
local treesitter = require('grug-far/render/treesitter')
local ResultHighlightType = require('grug-far/engine').ResultHighlightType

local M = {}

--- sets buf lines, even when buf is not modifiable
---@param buf integer
---@param start integer
---@param ending integer
---@param strict_indexing boolean
---@param replacement string[]
local function setBufLines(buf, start, ending, strict_indexing, replacement)
  local isModifiable = vim.api.nvim_get_option_value('modifiable', { buf = buf })
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, start, ending, strict_indexing, replacement)
  vim.api.nvim_set_option_value('modifiable', isModifiable, { buf = buf })
end

--- sets location mark
---@param buf integer
---@param context GrugFarContext
---@param line integer
---@param markId? integer
---@param sign? ResultHighlightSign
---@return integer markId
local function setLocationMark(buf, context, line, markId, sign)
  local sign_text = sign and opts.getIcon(sign.icon, context) or nil
  return vim.api.nvim_buf_set_extmark(buf, context.locationsNamespace, line, 0, {
    right_gravity = true,
    id = markId,
    sign_text = sign_text,
    sign_hl_group = sign and sign.hl or nil,
  })
end

--- sets location mark
---@param context GrugFarContext
---@param line integer
---@param loc ResultLocation
local function addHighlightResult(context, line, loc)
  local from = loc.text:match('^(%d+:%d+:)') or loc.text:match('^(%d+%-)')
  if not from then
    return
  end
  local results = context.state.highlightResults[loc.filename]
  if not results then
    results = {
      lines = {},
      ft = utils.getFileType(loc.filename),
    }
    context.state.highlightResults[loc.filename] = results
  end
  if not results.ft then
    -- we still keep it in results, so that we don't
    -- try to detect the filetype again
    return
  end
  local res = { row = line, col = #from, end_col = #loc.text, lnum = loc.lnum }
  table.insert(results.lines, res)
end

--- append a bunch of result lines to the buffer
---@param buf integer
---@param context GrugFarContext
---@param data ParsedResultsData
function M.appendResultsChunk(buf, context, data)
  -- add text
  local lastline = vim.api.nvim_buf_line_count(buf)
  setBufLines(buf, lastline, lastline, false, data.lines)
  -- add highlights
  for i = 1, #data.highlights do
    local highlight = data.highlights[i]
    for j = highlight.start_line, highlight.end_line do
      vim.api.nvim_buf_add_highlight(
        buf,
        context.namespace,
        highlight.hl,
        lastline + j,
        j == highlight.start_line and highlight.start_col or 0,
        j == highlight.end_line and highlight.end_col or -1
      )
    end
  end

  -- compute result locations based on highlights and add location marks
  -- those are used for actions like quickfix list and go to location
  local state = context.state
  local resultLocationByExtmarkId = state.resultLocationByExtmarkId
  ---@type ResultLocation?
  local lastLocation = nil

  for i = 1, #data.highlights do
    local highlight = data.highlights[i]
    local hl_type = highlight.hl_type
    local line = data.lines[highlight.start_line + 1]

    if hl_type == ResultHighlightType.FilePath then
      state.resultsLastFilename = string.sub(line, highlight.start_col + 1, highlight.end_col + 1)
      local markId = setLocationMark(buf, context, lastline + highlight.start_line)
      resultLocationByExtmarkId[markId] = { filename = state.resultsLastFilename }
    elseif hl_type == ResultHighlightType.LineNumber then
      -- omit ending ':'
      lastLocation = { filename = state.resultsLastFilename }
      local markId =
        setLocationMark(buf, context, lastline + highlight.start_line, nil, highlight.sign)
      resultLocationByExtmarkId[markId] = lastLocation

      lastLocation.sign = highlight.sign
      lastLocation.lnum = tonumber(string.sub(line, highlight.start_col + 1, highlight.end_col))
      lastLocation.text = line
      if context.options.resultsHighlight and lastLocation.text then
        addHighlightResult(context, lastline + highlight.start_line, lastLocation)
      end
    elseif
      hl_type == ResultHighlightType.ColumnNumber
      and lastLocation
      and not lastLocation.col
    then
      -- omit ending ':', use first match on that line
      lastLocation.col = tonumber(string.sub(line, highlight.start_col + 1, highlight.end_col))
      lastLocation.end_col = highlight.end_col
    elseif hl_type == ResultHighlightType.DiffSeparator then
      setLocationMark(buf, context, lastline + highlight.start_line, nil, highlight.sign)
    end
  end
  M.throttledHighlight(buf, context)
end

--- gets result location at given row if available
--- note: row is zero-based
--- additional note: sometimes there are mulltiple marks on the same row, like when lines
--- before this line are deleted, but the last mark should be the correct one.
---@param row integer
---@param buf integer
---@param context GrugFarContext
---@return ResultLocation | nil
function M.getResultLocation(row, buf, context)
  local marks = vim.api.nvim_buf_get_extmarks(
    buf,
    context.locationsNamespace,
    { row, 0 },
    { row, 0 },
    {}
  )
  if #marks > 0 then
    local markId = unpack(marks[#marks])
    return context.state.resultLocationByExtmarkId[markId]
  end

  return nil
end

--- displays results error
---@param buf integer
---@param context GrugFarContext
---@param error string | nil
function M.setError(buf, context, error)
  M.clear(buf, context)

  local startLine = context.state.headerRow + 1

  local err_lines = vim.split((error and #error > 0) and error or 'Unexpected error!', '\n')
  setBufLines(buf, startLine, startLine, false, err_lines)

  for i = startLine, startLine + #err_lines do
    vim.api.nvim_buf_add_highlight(buf, context.namespace, 'DiagnosticError', i, 0, -1)
  end
end

--- displays results warning
---@param buf integer
---@param context GrugFarContext
---@param warning string | nil
function M.appendWarning(buf, context, warning)
  if not (warning and #warning > 0) then
    return
  end
  local lastline = vim.api.nvim_buf_line_count(buf)

  local warn_lines = vim.split('\n\n' .. warning, '\n')
  setBufLines(buf, lastline, lastline, false, warn_lines)

  for i = lastline, lastline + #warn_lines - 1 do
    vim.api.nvim_buf_add_highlight(buf, context.namespace, 'DiagnosticWarn', i, 0, -1)
  end
end

---@alias Extmark integer[]

---@param all_extmarks Extmark[]
---@return Extmark[]
function M.filterDeletedLinesExtmarks(all_extmarks)
  local marksByRow = {}
  for i = 1, #all_extmarks do
    local mark = all_extmarks[i]
    marksByRow[mark[2]] = mark
  end

  local marks = {}
  for _, mark in pairs(marksByRow) do
    table.insert(marks, mark)
  end

  return marks
end

--- iterates over each location in the results list that has text which
--- has been changed by the user
---@param buf integer
---@param context GrugFarContext
---@param startRow integer
---@param endRow integer
---@param callback fun(location: ResultLocation, newLine: string, bufline: string, markId: integer, row: integer)
---@param forceChanged? boolean
function M.forEachChangedLocation(buf, context, startRow, endRow, callback, forceChanged)
  local all_extmarks = vim.api.nvim_buf_get_extmarks(
    buf,
    context.locationsNamespace,
    { startRow, 0 },
    { endRow, -1 },
    {}
  )

  -- filter out extraneous extmarks caused by deletion of lines
  local extmarks = M.filterDeletedLinesExtmarks(all_extmarks)

  for i = 1, #extmarks do
    local markId, row = unpack(extmarks[i])

    -- get the associated location info
    local location = context.state.resultLocationByExtmarkId[markId]
    if location and location.text then
      -- get the current text on row
      local bufline = unpack(vim.api.nvim_buf_get_lines(buf, row, row + 1, false))
      local isChanged = forceChanged or bufline ~= location.text
      if bufline and isChanged then
        -- ignore ones where user has messed with row:col: or row- prefix as we can't get actual changed text
        local prefix_end = location.end_col and location.end_col + 1 or #tostring(location.lnum) + 1
        local numColPrefix = string.sub(location.text, 1, prefix_end + 1)
        if vim.startswith(bufline, numColPrefix) then
          local newLine = string.sub(bufline, prefix_end + 1, -1)
          callback(location, newLine, bufline, markId, row)
        end
      end
    end
  end
end

--- marks un-synced lines
---@param buf integer
---@param context GrugFarContext
---@param startRow? integer
---@param endRow? integer
---@param sync? boolean whether to sync with current line contents, this removes indicators
function M.markUnsyncedLines(buf, context, startRow, endRow, sync)
  if not context.engine.isSyncSupported() then
    return
  end
  if not opts.getIcon('resultsChangeIndicator', context) then
    return
  end
  local changedSign = {
    icon = 'resultsChangeIndicator',
    hl = 'GrugFarResultsChangeIndicator',
  }

  local extmarks = vim.api.nvim_buf_get_extmarks(
    buf,
    context.locationsNamespace,
    { startRow or 0, 0 },
    { endRow or -1, -1 },
    {}
  )
  if #extmarks == 0 then
    return
  end

  -- reset marks
  for i = 1, #extmarks do
    local markId, row = unpack(extmarks[i]) --[[@as integer, integer]]
    local location = context.state.resultLocationByExtmarkId[markId]
    if location and location.text then
      setLocationMark(buf, context, row, markId)
    end
  end

  -- update the ones that are changed
  M.forEachChangedLocation(
    buf,
    context,
    startRow or 0,
    endRow or -1,
    function(location, _, bufLine, markId, row)
      if sync then
        location.text = bufLine
      else
        setLocationMark(buf, context, row, markId, location.sign or changedSign)
      end
    end,
    context.engine.isSearchWithReplacement(context.state.inputs, context.options)
  )
end

--- clears results area
---@param buf integer
---@param context GrugFarContext
function M.clear(buf, context)
  -- remove all lines after heading and add one blank line
  local headerRow = context.state.headerRow
  setBufLines(buf, headerRow, -1, false, { '' })
  vim.api.nvim_buf_clear_namespace(buf, context.locationsNamespace, 0, -1)
  context.state.resultLocationByExtmarkId = {}
  context.state.resultsLastFilename = nil
  context.state.highlightResults = {}
  context.state.highlightRegions = {}
  if context.options.resultsHighlight then
    treesitter.clear(buf)
  end
end

--- appends search command to results list
---@param buf integer
---@param context GrugFarContext
---@param rgArgs string[]
function M.appendSearchCommand(buf, context, rgArgs)
  local cmd_path = context.options.engines[context.engine.type].path
  local lastline = vim.api.nvim_buf_line_count(buf)
  local header = 'Search Command:'
  local lines = { header }
  for i, arg in ipairs(rgArgs) do
    local line = vim.fn.shellescape(arg)
    if i == 1 then
      line = cmd_path .. ' ' .. line
    end
    if i < #rgArgs then
      line = line .. ' \\'
    end
    table.insert(lines, line)
  end
  table.insert(lines, '')
  table.insert(lines, '')

  setBufLines(buf, lastline, lastline, false, lines)
  vim.api.nvim_buf_add_highlight(
    buf,
    context.helpHlNamespace,
    'GrugFarResultsCmdHeader',
    lastline,
    0,
    #header
  )
end

--- force redraws buffer. This is order to apear more responsive to the user
--- and quickly give user feedback as results come in / data is updated
---@param buf integer
function M.forceRedrawBuffer(buf)
  ---@diagnostic disable-next-line
  if vim.api.nvim__redraw then
    ---@diagnostic disable-next-line
    vim.api.nvim__redraw({ buf = buf, flush = true })
  end
end

---@param buf number
---@param context GrugFarContext
function M.highlight(buf, context)
  if not context.options.resultsHighlight then
    return
  end
  local regions = context.state.highlightRegions

  -- Process any pending results
  for filename, results in pairs(context.state.highlightResults) do
    results[filename] = nil
    if results.ft then
      local lang = vim.treesitter.language.get_lang(results.ft) or results.ft or 'lua'
      regions[lang] = regions[lang] or {}
      local last_line ---@type number?
      for _, line in ipairs(results.lines) do
        local node = { line.row, line.col, line.row, line.end_col }
        -- put consecutive lines in the same region
        if line.lnum - 1 ~= last_line then
          table.insert(regions[lang], {})
        end
        last_line = line.lnum
        local last = regions[lang][#regions[lang]]
        table.insert(last, node)
      end
    end
  end
  context.state.highlightResults = {}

  -- Attach the regions to the buffer
  if not vim.tbl_isempty(regions) then
    treesitter.attach(buf, regions)
  end
end

M.throttledHighlight = utils.throttle(M.highlight, 40)
M.throttledForceRedrawBuffer = utils.throttle(M.forceRedrawBuffer, 40)

return M
