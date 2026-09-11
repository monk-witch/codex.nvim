local M = {}

local bit = bit or bit32

local defaults = {
  codex_command = "codex",
  auto_start = true,
  connect_timeout_ms = 5000,
  list_limit = 100,
  socket_path = nil,
}

local config = vim.deepcopy(defaults)

local state = {
  connect_timer = nil,
  handshaken = false,
  next_request_id = 1,
  on_ready = {},
  pending = {},
  ready = false,
  selected_thread = nil,
  socket = nil,
  starting = false,
  transport_buffer = "",
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "codex.nvim" })
end

local function socket_path()
  if config.socket_path then
    return config.socket_path
  end

  local codex_home = vim.env.CODEX_HOME or vim.fn.expand("~/.codex")
  return codex_home .. "/app-server-control/app-server-control.sock"
end

local function clear_connect_timer()
  if state.connect_timer then
    state.connect_timer:stop()
    state.connect_timer:close()
    state.connect_timer = nil
  end
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

local function disconnect(message)
  clear_connect_timer()

  local socket = state.socket
  state.socket = nil
  state.handshaken = false
  state.ready = false
  state.starting = false
  state.transport_buffer = ""

  if socket and not socket:is_closing() then
    socket:read_stop()
    socket:close()
  end

  fail_pending(message)
  fail_waiters(message)
end

local function random_bytes(length)
  local ok, bytes = pcall(vim.uv.random, length)
  if ok and type(bytes) == "string" and #bytes == length then
    return bytes
  end

  local values = {}
  local seed = vim.uv.hrtime() % 2147483647
  for index = 1, length do
    seed = (seed * 1103515245 + 12345) % 2147483647
    values[index] = string.char(seed % 256)
  end
  return table.concat(values)
end

local function encode_frame(payload, opcode)
  local length = #payload
  if length > 65535 then
    return nil, "WebSocket payload is too large"
  end

  local mask = random_bytes(4)
  local header = string.char(0x80 + (opcode or 0x1))
  if length < 126 then
    header = header .. string.char(0x80 + length)
  else
    header = header .. string.char(0x80 + 126, math.floor(length / 256), length % 256)
  end

  local masked = {}
  for index = 1, length do
    masked[index] = string.char(bit.bxor(payload:byte(index), mask:byte(((index - 1) % 4) + 1)))
  end

  return header .. mask .. table.concat(masked)
end

local function send_frame(payload, opcode)
  if not state.socket or not state.handshaken then
    return false, "Codex App Server is not connected"
  end

  local frame, frame_err = encode_frame(payload, opcode)
  if not frame then
    return false, frame_err
  end

  local ok, err = pcall(state.socket.write, state.socket, frame)
  if not ok then
    return false, err
  end
  return true
end

local function send(message)
  return send_frame(vim.json.encode(message), 0x1)
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

local function handle_text(payload)
  local ok, message = pcall(vim.json.decode, payload)
  if ok then
    handle_message(message)
  else
    notify("Ignored malformed App Server response: " .. message, vim.log.levels.WARN)
  end
end

local function consume_frames()
  while true do
    local buffer = state.transport_buffer
    if #buffer < 2 then
      return
    end

    local first, second = buffer:byte(1, 2)
    local opcode = bit.band(first, 0x0f)
    local masked = bit.band(second, 0x80) ~= 0
    local length = bit.band(second, 0x7f)
    local position = 3

    if length == 126 then
      if #buffer < 4 then
        return
      end
      local high, low = buffer:byte(3, 4)
      length = high * 256 + low
      position = 5
    elseif length == 127 then
      disconnect("Codex App Server sent an unsupported WebSocket payload size")
      return
    end

    local mask
    if masked then
      if #buffer < position + 3 then
        return
      end
      mask = buffer:sub(position, position + 3)
      position = position + 4
    end

    local final_position = position + length - 1
    if #buffer < final_position then
      return
    end

    local payload = buffer:sub(position, final_position)
    state.transport_buffer = buffer:sub(final_position + 1)

    if mask then
      local unmasked = {}
      for index = 1, #payload do
        unmasked[index] = string.char(bit.bxor(payload:byte(index), mask:byte(((index - 1) % 4) + 1)))
      end
      payload = table.concat(unmasked)
    end

    if opcode == 0x1 then
      handle_text(payload)
    elseif opcode == 0x8 then
      disconnect("Codex App Server closed the connection")
      return
    elseif opcode == 0x9 then
      send_frame(payload, 0xA)
    end
  end
end

local function begin_protocol()
  local initialize_id = state.next_request_id
  state.next_request_id = initialize_id + 1
  state.pending[initialize_id] = function(err)
    if err then
      disconnect(err)
      return
    end

    local sent, send_err = send({ method = "initialized", params = {} })
    if not sent then
      disconnect(send_err)
      return
    end

    clear_connect_timer()
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
        version = "0.0.5",
      },
    },
  })

  if not ok then
    state.pending[initialize_id] = nil
    disconnect(err)
  end
end

local function consume_transport_data(data)
  state.transport_buffer = state.transport_buffer .. data

  if not state.handshaken then
    local boundary = state.transport_buffer:find("\r\n\r\n", 1, true)
    if not boundary then
      return
    end

    local response = state.transport_buffer:sub(1, boundary - 1)
    state.transport_buffer = state.transport_buffer:sub(boundary + 4)
    if not response:match("^HTTP/1%.1 101") then
      disconnect("Codex App Server rejected the WebSocket handshake: " .. response:gsub("\r\n.*", ""))
      return
    end

    state.handshaken = true
    begin_protocol()
  end

  consume_frames()
end

local function start_socket()
  local socket = vim.uv.new_pipe(false)
  state.socket = socket

  socket:connect(socket_path(), function(connect_err)
    vim.schedule(function()
      if connect_err then
        disconnect("Could not connect to the Codex App Server socket: " .. connect_err)
        return
      end

      socket:read_start(function(read_err, data)
        vim.schedule(function()
          if read_err then
            disconnect("Codex App Server socket error: " .. read_err)
          elseif data then
            consume_transport_data(data)
          elseif state.socket then
            disconnect("Codex App Server socket closed")
          end
        end)
      end)

      local key = vim.base64.encode(random_bytes(16))
      local handshake = table.concat({
        "GET / HTTP/1.1",
        "Host: localhost",
        "Connection: Upgrade",
        "Upgrade: websocket",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
        "",
        "",
      }, "\r\n")

      local ok, write_err = pcall(socket.write, socket, handshake)
      if not ok then
        disconnect("Could not start the Codex App Server WebSocket handshake: " .. write_err)
      end
    end)
  end)
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

  state.connect_timer = vim.uv.new_timer()
  state.connect_timer:start(config.connect_timeout_ms, 0, vim.schedule_wrap(function()
    disconnect("Timed out connecting to the Codex App Server")
  end))

  ensure_daemon(function(err)
    if err then
      disconnect(err)
      return
    end
    start_socket()
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

local function select_thread(threads, callback)
  local choices = { { "Select Codex chat:\n", "Title" } }
  for index, thread in ipairs(threads) do
    choices[#choices + 1] = { string.format("%d. %s\n", index, format_thread(thread)), "Normal" }
  end
  vim.api.nvim_echo(choices, true, {})

  vim.fn.inputsave()
  local answer = vim.fn.input("Codex chat number (empty cancels): ")
  vim.fn.inputrestore()

  if answer == "" then
    callback(nil)
    return
  end

  local index = tonumber(answer)
  if not index or index % 1 ~= 0 or not threads[index] then
    notify("Enter a chat number from the list", vim.log.levels.WARN)
    callback(nil)
    return
  end

  callback(threads[index])
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

    select_thread(threads, function(thread)
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
