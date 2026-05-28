local state = require('opencode.state')
local config = require('opencode.config')

local loading_animation = require('opencode.ui.loading_animation')
local Timer = require('opencode.ui.timer')

local M = {}

M._indicator = {
  ns_id = vim.api.nvim_create_namespace('opencode_background_indicator'),
  buf = nil,
  win = nil,
  timer = nil,
  current_frame = 1,
  fps = 10,
  status_data = nil,
  status_event_manager = nil,
  augroup = nil,
}

local WRITE_TOOLS = {
  apply_patch = true,
  edit = true,
  write = true,
}

local function is_enabled()
  return config.ui.background_indicator and config.ui.background_indicator.enabled ~= false
end

local function get_frames()
  local ui_config = config.ui
  if ui_config and ui_config.loading_animation and ui_config.loading_animation.frames then
    return ui_config.loading_animation.frames
  end
  return { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
end

local function get_window_state_status()
  return state.ui.get_window_state().status
end

local function should_show()
  return is_enabled() and state.jobs.is_running() and get_window_state_status() == 'hidden'
end

M._should_show = should_show

local function build_text()
  local text = (loading_animation._format_status_text(M._indicator.status_data) or 'Thinking... ')
  local max_width = config.ui.background_indicator and config.ui.background_indicator.max_width
  if type(max_width) == 'number' and max_width > 0 then
    text = vim.fn.strcharpart(text, 0, max_width)
  end
  return text
end

local function collect_activity()
  local messages = state.messages or {}
  local tools = {}
  local tool_seen = {}
  local write_ops = 0
  local todos = {}

  for _, message in ipairs(messages) do
    for _, part in ipairs(message.parts or {}) do
      local tool = part.tool
      local status = part.state and part.state.status
      if tool and (status == 'pending' or status == 'in_progress') then
        if not tool_seen[tool] then
          table.insert(tools, tool)
          tool_seen[tool] = true
        end
        if WRITE_TOOLS[tool] then
          write_ops = write_ops + 1
        end
      end

      if part.tool == 'todowrite' then
        local items = part.state and part.state.input and part.state.input.todos
        if type(items) == 'table' then
          todos = items
        end
      end
    end
  end

  return {
    tools = tools,
    write_ops = write_ops,
    todos = todos,
  }
end

local function build_lines()
  local activity = collect_activity()
  local lines = {}
  local max_tools = ((config.ui.background_indicator or {}).max_tools) or 2
  local show_tool_activity = (config.ui.background_indicator or {}).show_tool_activity ~= false
  local status_line = nil

  local in_progress_todo
  for _, item in ipairs(activity.todos or {}) do
    if item.status == 'in_progress' and type(item.content) == 'string' and item.content ~= '' then
      in_progress_todo = item.content
      break
    end
  end

  if in_progress_todo then
    status_line = 'Working: ' .. in_progress_todo
  elseif show_tool_activity and #activity.tools > 0 then
    local shown = {}
    for i = 1, math.min(#activity.tools, max_tools) do
      table.insert(shown, activity.tools[i])
    end
    status_line = 'Running: ' .. table.concat(shown, ', ')
  elseif activity.write_ops > 0 then
    status_line = activity.write_ops > 1 and string.format('Writing %d files', activity.write_ops) or 'Writing files'
  else
    status_line = build_text()
  end

  local frame = get_frames()[M._indicator.current_frame]
  local bg = config.ui.background_indicator or {}
  local status_max_cols = bg.todo_max_cols or 29
  local status_ellipsis = bg.todo_ellipsis or '…'
  local first_line = status_line .. ' ' .. frame
  if vim.fn.strchars(first_line) > status_max_cols then
    local keep = math.max(0, status_max_cols - vim.fn.strchars(status_ellipsis))
    first_line = vim.fn.strcharpart(first_line, 0, keep) .. status_ellipsis
  end
  table.insert(lines, first_line)

  if (config.ui.background_indicator or {}).show_todos == false then
    return lines
  end

  local filtered = {}
  for _, item in ipairs(activity.todos or {}) do
    if item.status == 'pending' then
      table.insert(filtered, item)
    end
  end

  bg = config.ui.background_indicator or {}
  local max_todos = bg.max_todos or 5
  local todo_max_cols = bg.todo_max_cols or 29
  local pending_icon = bg.todo_pending_icon or '☐'
  local in_progress_icon = bg.todo_in_progress_icon or '⌚'
  local in_progress_fallback_icon = bg.todo_in_progress_fallback_icon or '>'
  local ellipsis = bg.todo_ellipsis or '…'
  local show_count = math.min(#filtered, max_todos)
  for i = 1, show_count do
    local item = filtered[i]
    local progress_icon = in_progress_icon ~= '' and in_progress_icon or in_progress_fallback_icon
    local mark = item.status == 'in_progress' and progress_icon or pending_icon
    local line = string.format('%s %s', mark, item.content or '')
    local line_len = vim.fn.strchars(line)
    if line_len > todo_max_cols then
      local suffix = (ellipsis ~= '' and ellipsis) or '...'
      local keep = math.max(0, todo_max_cols - vim.fn.strchars(suffix))
      line = vim.fn.strcharpart(line, 0, keep) .. suffix
    end
    table.insert(lines, line)
  end
  if #filtered > show_count then
    table.insert(lines, string.format('... +%d more', #filtered - show_count))
  end

  return lines
end

M._build_lines = build_lines

local function close_win()
  if M._indicator.win and vim.api.nvim_win_is_valid(M._indicator.win) then
    pcall(vim.api.nvim_win_close, M._indicator.win, true)
  end
  M._indicator.win = nil
end

local function ensure_buf()
  if M._indicator.buf and vim.api.nvim_buf_is_valid(M._indicator.buf) then
    return M._indicator.buf
  end
  M._indicator.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = M._indicator.buf })
  vim.api.nvim_set_option_value('filetype', 'opencode_background_indicator', { buf = M._indicator.buf })
  return M._indicator.buf
end

local function build_win_config(width)
  local offset = (config.ui.background_indicator and config.ui.background_indicator.offset) or {}
  local row = tonumber(offset.row) or 0
  local col_offset = tonumber(offset.col) or 1
  return {
    relative = 'editor',
    anchor = 'NE',
    row = row,
    col = vim.o.columns - col_offset,
    width = math.max(1, width),
    height = 1,
    focusable = false,
    style = 'minimal',
    border = 'none',
    zindex = 60,
  }
end

function M.render()
  if not should_show() then
    close_win()
    return false
  end

  local lines = build_lines()
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strchars(line))
  end
  local height = #lines
  local buf = ensure_buf()

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  if M._indicator.win and vim.api.nvim_win_is_valid(M._indicator.win) then
    local cfg = build_win_config(width)
    cfg.height = height
    vim.api.nvim_win_set_config(M._indicator.win, cfg)
  else
    local cfg = build_win_config(width)
    cfg.height = height
    M._indicator.win = vim.api.nvim_open_win(buf, false, cfg)
    vim.api.nvim_set_option_value('winhl', 'Normal:OpencodeHint', { win = M._indicator.win })
  end

  return true
end

local function stop_timer()
  if M._indicator.timer then
    M._indicator.timer:stop()
    M._indicator.timer = nil
  end
  M._indicator.current_frame = 1
end

local function start_timer()
  if M._indicator.timer then
    return
  end
  local interval = math.floor(1000 / M._indicator.fps)
  M._indicator.timer = Timer.new({
    interval = interval,
    repeat_timer = true,
    on_tick = function()
      M._indicator.current_frame = (M._indicator.current_frame % #get_frames()) + 1
      if not M.render() then
        stop_timer()
        return false
      end
      return true
    end,
  })
  M._indicator.timer:start()
end

local function on_state_change()
  if should_show() then
    start_timer()
    M.render()
  else
    stop_timer()
    close_win()
  end
end

function M.on_session_status(properties)
  if type(properties) ~= 'table' then
    return
  end
  local active_session = state.active_session
  if active_session and active_session.id and properties.sessionID ~= active_session.id then
    return
  end
  M._indicator.status_data = properties.status
  M.render()
end

local function unsubscribe_session_status_event(manager)
  if manager and M._indicator.status_event_manager == manager then
    manager:unsubscribe('session.status', M.on_session_status)
    M._indicator.status_event_manager = nil
  end
end

local function subscribe_session_status_event(manager)
  if not manager then
    return
  end
  if M._indicator.status_event_manager and M._indicator.status_event_manager ~= manager then
    unsubscribe_session_status_event(M._indicator.status_event_manager)
  end
  if M._indicator.status_event_manager == manager then
    return
  end
  manager:subscribe('session.status', M.on_session_status)
  M._indicator.status_event_manager = manager
end

local function on_event_manager_change(_, new_manager, old_manager)
  unsubscribe_session_status_event(old_manager)
  subscribe_session_status_event(new_manager)
end

function M.setup()
  state.store.subscribe('job_count', on_state_change)
  state.store.subscribe('windows', on_state_change)
  state.store.subscribe('messages', on_state_change)
  state.store.subscribe('active_session', function() M._indicator.status_data = nil end)
  state.store.subscribe('event_manager', on_event_manager_change)
  subscribe_session_status_event(state.event_manager)

  M._indicator.augroup = vim.api.nvim_create_augroup('OpencodeBackgroundIndicator', { clear = true })
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = M._indicator.augroup,
    callback = function()
      M.render()
    end,
  })
end

function M.teardown()
  state.store.unsubscribe('job_count', on_state_change)
  state.store.unsubscribe('windows', on_state_change)
  state.store.unsubscribe('messages', on_state_change)
  state.store.unsubscribe('event_manager', on_event_manager_change)
  unsubscribe_session_status_event(M._indicator.status_event_manager)
  if M._indicator.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M._indicator.augroup)
    M._indicator.augroup = nil
  end
  stop_timer()
  close_win()
end

return M
