local M = {}

local defaults = {
  codex_command = "codex",
  auto_start = true,
  list_limit = 100,
}

local config = vim.deepcopy(defaults)

local state = {
  client = nil,
  ready = false,
  starting = false,
  stdout = "",
  stderr = "",
  next_request_id = 1,
  pending = {},
  on_ready = {},
  selected_thread = nil,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "codex.nvim" })
end

local function fail_pending(message)
  for id, callback in pairs(state.pending) do
    state.pending[id] = nil
    callback(message, nil)
  end
end

local function fail_waiters(message)
  local waiters = state.on_ready
  state.on_ready = {}
  for _, callback in ipairs(waiters) do
    callback(message)
  end
end

local function send(message)
  if not state.client then
    return false, "Codex App Server is not connected"
  end

  local ok, err = pcall(state.client.write, state.client, vim.json.encode(message) .. "\n")
  if not ok then
    return false, err
  end

  return true
end

local function request(method, params, callback)
  if not state.ready then
    callback("Codex App Server is not ready", nil)
    return
  end

  local id = state.next_request_id
  state.next_request_id = id + 1
  state.pending[id] = callback

  local ok, err = send({ method = method, id = id, params = params })
  if not ok then
    state.pending[id] = nil
    callback(err, nil)
  end
end

local function handle_message(message)
  if not message.id then
    return
  end

  local callback = state.pending[message.id]
  if not callback then
    return
  end
  state.pending[message.id] = nil

  if message.error then
    callback(message.error.message or "Codex App Server request failed", nil)
    return
  end

  callback(nil, message.result)
end

local function read_stdout(_, chunk)
  if not chunk or chunk == "" then
    return
  end

  vim.schedule(function()
    state.stdout = state.stdout .. chunk

    while true do
      local newline = state.stdout:find("\n", 1, true)
      if not newline then
        break
      end

      local line = state.stdout:sub(1, newline - 1)
      state.stdout = state.stdout:sub(newline + 1)

      if line ~= "" then
        local ok, message = pcall(vim.json.decode, line)
        if ok then
          handle_message(message)
        else
          notify("Ignored malformed App Server response: " .. message, vim.log.levels.WARN)
        end
      end
    end
  end)
end

local function read_stderr(_, chunk)
  if chunk and chunk ~= "" then
    state.stderr = state.stderr .. chunk
  end
end

local function start_proxy(callback)
  state.client = vim.system({ config.codex_command, "app-server", "proxy" }, {
    stdin = true,
    text = true,
    stdout = read_stdout,
    stderr = read_stderr,
  }, function(result)
    vim.schedule(function()
      local stderr = vim.trim(state.stderr)
      state.client = nil
      state.ready = false
      state.starting = false
      state.stdout = ""
      state.stderr = ""

      local message = "Codex App Server proxy stopped"
      if result.code ~= 0 then
        message = message .. " (exit " .. result.code .. ")"
      end
      if stderr ~= "" then
        message = message .. ": " .. stderr
      end

      fail_pending(message)
      fail_waiters(message)
    end)
  end)

  local initialize_id = state.next_request_id
  state.next_request_id = initialize_id + 1
  state.pending[initialize_id] = function(err)
    if err then
      state.starting = false
      fail_waiters(err)
      return
    end

    local sent, send_err = send({ method = "initialized", params = {} })
    if not sent then
      state.starting = false
      fail_waiters(send_err)
      return
    end

    state.ready = true
    state.starting = false
    local waiters = state.on_ready
    state.on_ready = {}
    for _, waiter in ipairs(waiters) do
      waiter(nil)
    end
  end

  local ok, err = send({
    method = "initialize",
    id = initialize_id,
    params = {
      clientInfo = {
        name = "codex.nvim",
        title = "codex.nvim",
        version = "0.0.2",
      },
    },
  })

  if not ok then
    state.pending[initialize_id] = nil
    state.starting = false
    fail_waiters(err)
  end
end

local function ensure_daemon(callback)
  if not config.auto_start then
    callback(nil)
    return
  end

  vim.system({ config.codex_command, "app-server", "daemon", "start" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = vim.trim(result.stderr or result.stdout or "")
        callback("Could not start the Codex App Server daemon" .. (detail ~= "" and ": " .. detail or ""))
        return
      end
      callback(nil)
    end)
  end)
end

local function connect(callback)
  if state.ready then
    callback(nil)
    return
  end

  table.insert(state.on_ready, callback)
  if state.starting then
    return
  end
  state.starting = true

  ensure_daemon(function(err)
    if err then
      state.starting = false
      fail_waiters(err)
      return
    end
    start_proxy()
  end)
end

local function format_thread(thread)
  local title = thread.name or thread.preview or "Untitled Codex chat"
  local pinned = thread.isPinned and "[pinned] " or ""
  local updated = ""

  if type(thread.updatedAt) == "number" then
    updated = os.date("%Y-%m-%d %H:%M", thread.updatedAt)
  end

  if updated ~= "" then
    return string.format("%s%s — %s", pinned, title, updated)
  end
  return pinned .. title
end

--- Fetch the interactive, non-archived Codex chats for NeoVim's current project.
--- @param callback fun(err: string|nil, threads: table[]|nil)
function M.list_chats(callback)
  connect(function(err)
    if err then
      callback(err, nil)
      return
    end

    request("thread/list", {
      limit = config.list_limit,
      sortKey = "updated_at",
      sortDirection = "desc",
      archived = false,
      cwd = vim.fn.getcwd(0),
    }, function(request_err, result)
      if request_err then
        callback(request_err, nil)
        return
      end
      callback(nil, result.data or {})
    end)
  end)
end

--- Open NeoVim's native selector and retain the chosen thread for this NeoVim instance.
function M.list()
  M.list_chats(function(err, threads)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    if #threads == 0 then
      notify("No active Codex chats found for " .. vim.fn.getcwd(0))
      return
    end

    vim.ui.select(threads, {
      prompt = "Select Codex chat",
      format_item = format_thread,
    }, function(thread)
      if not thread then
        return
      end

      state.selected_thread = thread
      notify("Selected Codex chat: " .. (thread.name or thread.preview or thread.id))
    end)
  end)
end

--- Return the chat selected for this NeoVim instance, or nil.
function M.selected_chat()
  return state.selected_thread
end

--- Return the selected chat's ID, or nil.
function M.selected_chat_id()
  return state.selected_thread and state.selected_thread.id or nil
end

--- Clear the chat selected for this NeoVim instance.
function M.clear_selection()
  state.selected_thread = nil
end

function M.setup(options)
  config = vim.tbl_deep_extend("force", config, options or {})

  vim.api.nvim_create_user_command("CodexList", function()
    M.list()
  end, {
    desc = "Select an active Codex chat for this NeoVim instance",
  })

  vim.api.nvim_create_user_command("CodexLS", function()
    M.list()
  end, {
    desc = "Alias for :CodexList",
  })
end

return M
