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
  end)

  after_each(function()
    state.jobs.is_running = original_is_running
    state.ui.get_window_state = original_get_window_state
    config.ui.background_indicator.enabled = original_enabled
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
end)
