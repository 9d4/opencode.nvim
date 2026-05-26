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
  local base = loading_animation._format_status_text(M._indicator.status_data) or 'Thinking... '
  local frame = get_frames()[M._indicator.current_frame]
  local text = base .. frame
  local max_width = config.ui.background_indicator and config.ui.background_indicator.max_width
  if type(max_width) == 'number' and max_width > 0 then
    text = vim.fn.strcharpart(text, 0, max_width)
  end
  return text
end

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

  local text = build_text()
  local width = vim.fn.strchars(text)
  local buf = ensure_buf()

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  if M._indicator.win and vim.api.nvim_win_is_valid(M._indicator.win) then
    vim.api.nvim_win_set_config(M._indicator.win, build_win_config(width))
  else
    M._indicator.win = vim.api.nvim_open_win(buf, false, build_win_config(width))
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
