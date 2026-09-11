local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local defaults = {
  enabled = true,
  delay_ms = 120,
  interval_ms = 100,
  success_duration_ms = 1500,
}

local config = vim.deepcopy(defaults)

local state = {
  active = {},
  completion = nil,
  completion_timer = nil,
  delay_timer = nil,
  frame = 1,
  next_id = 1,
  order = {},
  redraw_scheduled = false,
  timer = nil,
  visible = false,
}

local function stop_timer(name)
  local timer = state[name]
  state[name] = nil

  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function request_redraw()
  if state.redraw_scheduled then
    return
  end

  state.redraw_scheduled = true
  vim.schedule(function()
    state.redraw_scheduled = false
    pcall(vim.cmd, "redrawstatus")
  end)
end

local function has_active_operation()
  return next(state.active) ~= nil
end

local function stop_animation()
  stop_timer("delay_timer")
  stop_timer("timer")
  state.visible = false
  request_redraw()
end

local function clear_completion()
  stop_timer("completion_timer")
  state.completion = nil
end

local function show_completion(message)
  stop_animation()
  state.completion = { frame = state.frame, message = message }
  state.visible = true
  request_redraw()

  local timer = vim.uv.new_timer()
  state.completion_timer = timer
  timer:start(
    config.success_duration_ms,
    0,
    vim.schedule_wrap(function()
      if state.completion_timer ~= timer then
        return
      end

      stop_timer("completion_timer")
      state.completion = nil
      state.visible = false
      request_redraw()
    end)
  )
end

local function advance_frame()
  state.frame = (state.frame % #frames) + 1
  request_redraw()
end

local function start_animation()
  if state.timer or not state.visible then
    return
  end

  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(
    config.interval_ms,
    config.interval_ms,
    vim.schedule_wrap(function()
      if state.timer ~= timer then
        return
      end

      if not has_active_operation() then
        stop_animation()
        return
      end

      advance_frame()
    end)
  )
end

local function show_after_delay()
  if not has_active_operation() then
    return
  end

  state.visible = true
  state.frame = 1
  start_animation()
  request_redraw()
end

local function start_delay()
  if state.delay_timer or state.visible then
    return
  end

  if config.delay_ms <= 0 then
    show_after_delay()
    return
  end

  local timer = vim.uv.new_timer()
  state.delay_timer = timer
  timer:start(
    config.delay_ms,
    0,
    vim.schedule_wrap(function()
      if state.delay_timer ~= timer then
        return
      end

      stop_timer("delay_timer")
      show_after_delay()
    end)
  )
end

local function current_operation()
  for index = #state.order, 1, -1 do
    local id = state.order[index]
    local operation = state.active[id]
    if operation then
      return operation
    end
  end
end

--- Configure the statusline progress indicator.
--- @param options table|nil
function M.setup(options)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
end

--- Start a statusline operation and return a token that must be stopped.
--- @param message string
--- @return table|nil token
function M.start(message)
  if not config.enabled then
    return nil
  end

  if state.completion then
    clear_completion()
    state.visible = false
  end

  local token = { id = state.next_id }
  state.next_id = state.next_id + 1
  state.active[token.id] = { message = message }
  state.order[#state.order + 1] = token.id

  start_delay()
  return token
end

--- Stop a previously started statusline operation.
--- @param token table|nil
--- @param success_message string|nil
function M.stop(token, success_message)
  if not token or not state.active[token.id] then
    return
  end

  state.active[token.id] = nil
  if not has_active_operation() then
    if success_message then
      show_completion(success_message)
    else
      stop_animation()
    end
  else
    request_redraw()
  end
end

--- Return the transient Codex statusline segment, or an empty string while idle.
--- @return string
function M.statusline()
  if state.completion then
    return string.format(" ·   %s", state.completion.message)
  end

  local operation = current_operation()
  if not state.visible or not operation then
    return ""
  end

  return string.format(" · %s %s", frames[state.frame], operation.message)
end

--- Return whether one or more Codex operations are running.
--- @return boolean
function M.is_busy()
  return has_active_operation()
end

return M
