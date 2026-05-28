local state = require('opencode.state')
local config = require('opencode.config')
local indicator = require('opencode.ui.background_indicator')

describe('background_indicator visibility', function()
  local original_is_running
  local original_get_window_state
  local original_enabled

  before_each(function()
    original_is_running = state.jobs.is_running
    original_get_window_state = state.ui.get_window_state
    original_enabled = config.ui.background_indicator.enabled
    config.ui.background_indicator.show_todos = true
    state.renderer.set_messages({})
  end)

  after_each(function()
    state.jobs.is_running = original_is_running
    state.ui.get_window_state = original_get_window_state
    config.ui.background_indicator.enabled = original_enabled
    state.renderer.set_messages({})
  end)

  it('shows only when hidden and running', function()
    config.ui.background_indicator.enabled = true
    state.jobs.is_running = function()
      return true
    end
    state.ui.get_window_state = function()
      return { status = 'hidden' }
    end
    assert.is_true(indicator._should_show())

    state.ui.get_window_state = function()
      return { status = 'visible' }
    end
    assert.is_false(indicator._should_show())

    state.jobs.is_running = function()
      return false
    end
    state.ui.get_window_state = function()
      return { status = 'hidden' }
    end
    assert.is_false(indicator._should_show())
  end)

  it('renders pending and in_progress todos only', function()
    config.ui.background_indicator.todo_max_cols = 29
    state.renderer.set_messages({
      {
        parts = {
          {
            tool = 'todowrite',
            state = {
              input = {
                todos = {
                  { content = 'pending item', status = 'pending' },
                  { content = 'working item with a very long content to truncate', status = 'in_progress' },
                  { content = 'done item', status = 'completed' },
                },
              },
            },
          },
        },
      },
    })

    local lines = indicator._build_lines()
    local text = table.concat(lines, '\n')
    assert.is_truthy(lines[1]:find('Working:', 1, true))
    assert.is_truthy(text:find('☐ pending item', 1, true))
    assert.is_falsy(text:find('☐ working item', 1, true))
    assert.is_falsy(text:find('done item', 1, true))
    assert.is_falsy(text:find('%- %['))
    for _, line in ipairs(lines) do
      if line:find('pending item', 1, true) or line:find('Working:', 1, true) then
        assert.is_true(vim.fn.strchars(line) < 30)
      end
    end
  end)
end)
