local M = {}

local bit = bit or bit32
local progress = require("codex.progress")

local plugin_version = "0.0.13"
local minimum_codex_version = { 0, 154, 0 }
local minimum_nvim_version = { 0, 12, 5 }

local defaults = {
  codex_command = "codex",
  auto_start = true,
  connect_timeout_ms = 5000,
  list_limit = 100,
  max_websocket_payload_bytes = 16 * 1024 * 1024,
  progress = {
    delay_ms = 120,
    enabled = true,
    interval_ms = 100,
  },
  selection = {
    persist = true,
    state_path = nil,
  },
  socket_path = nil,
  statusline = {
    attach_to_default = true,
  },
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
  selection_restored_path = nil,
  socket = nil,
  starting = false,
  transport_buffer = "",
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "codex.nvim" })
end

local function format_version(version)
  return table.concat(version, ".")
end

local function is_version_at_least(actual, minimum)
  for index = 1, #minimum do
    local actual_part = actual[index] or 0
    if actual_part ~= minimum[index] then
      return actual_part > minimum[index]
    end
  end
  return true
end

local function nvim_requirement_error()
  local version = vim.version()
  local actual = { version.major, version.minor, version.patch }
  if is_version_at_least(actual, minimum_nvim_version) then
    return nil
  end

  return string.format(
    "codex.nvim requires NeoVim %s or newer (found %s)",
    format_version(minimum_nvim_version),
    format_version(actual)
  )
end

local function parse_version(output)
  local major, minor, patch = output:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function socket_path()
  if config.socket_path then
    return config.socket_path
  end

  local codex_home = vim.env.CODEX_HOME or vim.fn.expand("~/.codex")
  return codex_home .. "/app-server-control/app-server-control.sock"
end

local function selection_state_path()
  if config.selection.state_path then
    return config.selection.state_path
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "codex.nvim", "selection.json")
end

local function selection_store()
  return { version = 1, selections = {} }
end

local function read_selection_store()
  local path = selection_state_path()
  if vim.fn.filereadable(path) ~= 1 then
    return selection_store()
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" or type(decoded.selections) ~= "table" then
    return selection_store()
  end
  return decoded
end

local function write_selection_store(store)
  local path = selection_state_path()
  local directory = vim.fs.dirname(path)
  vim.fn.mkdir(directory, "p")

  local temporary_path = path .. ".tmp"
  local ok, write_err = pcall(vim.fn.writefile, { vim.json.encode(store) }, temporary_path)
  if not ok then
    notify("Could not save the Codex chat selection: " .. write_err, vim.log.levels.WARN)
    return
  end

  local renamed, rename_err = vim.uv.fs_rename(temporary_path, path)
  if not renamed then
    pcall(vim.uv.fs_unlink, temporary_path)
    notify("Could not save the Codex chat selection: " .. rename_err, vim.log.levels.WARN)
  end
end

local function stored_thread(thread)
  return {
    id = thread.id,
    isPinned = thread.isPinned,
    name = thread.name,
    preview = thread.preview,
    updatedAt = thread.updatedAt,
  }
end

local function persist_selection()
  if not config.selection.persist then
    return
  end

  local store = read_selection_store()
  local cwd = vim.fn.getcwd(0)
  if state.selected_thread then
    store.selections[cwd] = stored_thread(state.selected_thread)
  else
    store.selections[cwd] = nil
  end
  write_selection_store(store)
end

local function restore_selection()
  if not config.selection.persist then
    return
  end

  local path = selection_state_path()
  if state.selection_restored_path == path then
    return
  end
  state.selection_restored_path = path

  local thread = read_selection_store().selections[vim.fn.getcwd(0)]
  if type(thread) == "table" and type(thread.id) == "string" and thread.id ~= "" then
    state.selected_thread = stored_thread(thread)
  end
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

local function bytes_from_u64(value)
  local bytes = {}
  for index = 8, 1, -1 do
    bytes[index] = string.char(value % 256)
    value = math.floor(value / 256)
  end
  return table.concat(bytes)
end

local function u64_from_bytes(buffer, start_index)
  local value = 0
  for index = start_index, start_index + 7 do
    value = value * 256 + buffer:byte(index)
  end
  return value
end

local function encode_frame(payload, opcode)
  local length = #payload
  if length > config.max_websocket_payload_bytes then
    return nil, "WebSocket payload is too large"
  end

  local mask = random_bytes(4)
  local header = string.char(0x80 + (opcode or 0x1))
  if length < 126 then
    header = header .. string.char(0x80 + length)
  elseif length <= 65535 then
    header = header .. string.char(0x80 + 126, math.floor(length / 256), length % 256)
  else
    header = header .. string.char(0x80 + 127) .. bytes_from_u64(length)
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
      if #buffer < 10 then
        return
      end
      length = u64_from_bytes(buffer, 3)
      if length > config.max_websocket_payload_bytes then
        disconnect("Codex App Server sent a WebSocket payload that exceeds the configured limit")
        return
      end
      position = 11
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
        version = plugin_version,
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
      if state.socket ~= socket then
        if not socket:is_closing() then
          socket:close()
        end
        return
      end

      if connect_err then
        disconnect("Could not connect to the Codex App Server socket: " .. connect_err)
        return
      end

      socket:read_start(function(read_err, data)
        vim.schedule(function()
          if state.socket ~= socket then
            return
          end

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

local function check_codex_version(callback)
  vim.system({ config.codex_command, "--version" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = vim.trim(result.stderr or result.stdout or "")
        callback("Could not run Codex CLI --version" .. (detail ~= "" and ": " .. detail or ""))
        return
      end

      local version = parse_version(result.stdout or "")
      if not version then
        callback("Could not determine the Codex CLI version from: " .. vim.trim(result.stdout or ""))
        return
      end

      if not is_version_at_least(version, minimum_codex_version) then
        callback(string.format(
          "codex.nvim requires Codex CLI %s or newer (found %s)",
          format_version(minimum_codex_version),
          format_version(version)
        ))
        return
      end
      callback(nil)
    end)
  end)
end

local function ensure_daemon(callback)
  check_codex_version(function(version_err)
    if version_err then
      callback(version_err)
      return
    end

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

local statusline_component = "%{%v:lua.require'codex'.status()%}"

local function attach_statusline_to_default()
  if not config.statusline.attach_to_default then
    return
  end

  local info = vim.api.nvim_get_option_info2("statusline", {})
  if info.was_set or vim.o.statusline:find(statusline_component, 1, true) then
    return
  end

  local updated, substitutions = vim.o.statusline:gsub("%%f ", function()
    return "%f" .. statusline_component .. " "
  end, 1)

  if substitutions == 1 then
    vim.o.statusline = updated
  end
end

local function select_thread(threads, callback)
  local buffer = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for index, thread in ipairs(threads) do
    lines[index] = format_thread(thread)
  end

  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false

  local longest_line = 0
  for _, line in ipairs(lines) do
    longest_line = math.max(longest_line, vim.fn.strdisplaywidth(line))
  end

  local height = math.min(#lines, math.max(1, math.floor(vim.o.lines * 0.6)))
  local number_width = #tostring(#lines) + 1
  local width = math.min(longest_line + number_width, math.max(20, vim.o.columns - 8))
  local window = vim.api.nvim_open_win(buffer, true, {
    border = "rounded",
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    height = height,
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    style = "minimal",
    width = width,
  })

  vim.wo[window].cursorline = true
  vim.wo[window].number = true
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].wrap = false

  local finished = false
  local function close(thread)
    if finished then
      return
    end
    finished = true
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
    callback(thread)
  end

  local function choose()
    local index = vim.v.count
    if index == 0 then
      index = vim.api.nvim_win_get_cursor(window)[1]
    end
    close(threads[index])
  end

  local function map(keys, handler)
    vim.keymap.set("n", keys, handler, { buffer = buffer, nowait = true, silent = true })
  end

  map("<CR>", choose)
  map("<Esc>", function()
    close(nil)
  end)
  map("q", function()
    close(nil)
  end)
  map("<Up>", "k")
  map("<Down>", "j")

  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function(event)
      if tonumber(event.match) == window then
        close(nil)
      end
    end,
    once = true,
  })
end

--- Fetch the interactive, non-archived Codex chats for NeoVim's current project.
--- @param callback fun(err: string|nil, threads: table[]|nil)
function M.list_chats(callback)
  local requirement_err = nvim_requirement_error()
  if requirement_err then
    callback(requirement_err, nil)
    return
  end

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
  local requirement_err = nvim_requirement_error()
  if requirement_err then
    notify(requirement_err, vim.log.levels.ERROR)
    return
  end

  local operation = progress.start("Listing Codex chats…")
  M.list_chats(function(err, threads)
    progress.stop(operation)

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
      persist_selection()
    end)
  end)
end

--- Send text to the Codex chat selected for this NeoVim instance.
--- The selected thread is resumed before its new turn starts.
--- @param text string
--- @param callback fun(err: string|nil, turn: table|nil)
function M.send(text, callback)
  local requirement_err = nvim_requirement_error()
  if requirement_err then
    callback(requirement_err, nil)
    return
  end

  local thread = state.selected_thread
  if not thread or not thread.id then
    callback("Select a Codex chat with :CodexList before sending text", nil)
    return
  end

  if text == "" then
    callback("Cannot send an empty line range", nil)
    return
  end

  connect(function(connect_err)
    if connect_err then
      callback(connect_err, nil)
      return
    end

    request("thread/resume", { threadId = thread.id }, function(resume_err)
      if resume_err then
        callback(resume_err, nil)
        return
      end

      request("turn/start", {
        threadId = thread.id,
        input = {
          { type = "text", text = text },
        },
      }, function(turn_err, result)
        if turn_err then
          callback(turn_err, nil)
          return
        end
        callback(nil, result.turn)
      end)
    end)
  end)
end

--- Send the inclusive line range from the current buffer to the selected Codex chat.
--- @param line1 integer
--- @param line2 integer
function M.send_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  local text = table.concat(lines, "\n")
  M.chat(text)
end

--- Send direct input to the Codex chat selected for this NeoVim instance.
--- @param text string
function M.chat(text)
  local operation = progress.start("Sending input to Codex…")

  M.send(text, function(err)
    progress.stop(operation, err and nil or "Input sent")

    if err then
      notify(err, vim.log.levels.ERROR)
    end
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
  persist_selection()
end

--- Return the transient Codex statusline segment, or an empty string while idle.
--- Add this function to your custom statusline configuration.
--- @return string
function M.status()
  return progress.statusline()
end

--- Return whether Codex.nvim has an operation currently in progress.
--- @return boolean
function M.is_busy()
  return progress.is_busy()
end

function M.setup(options)
  config = vim.tbl_deep_extend("force", config, options or {})
  local requirement_err = nvim_requirement_error()
  if requirement_err then
    notify(requirement_err, vim.log.levels.ERROR)
  else
    progress.setup(config.progress)
    attach_statusline_to_default()
    restore_selection()
  end

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

  vim.api.nvim_create_user_command("CodexSend", function(command)
    M.send_range(command.line1, command.line2)
  end, {
    bar = true,
    desc = "Send the selected line range to the active Codex chat",
    range = true,
  })

  vim.api.nvim_create_user_command("CodexChat", function(command)
    M.chat(command.args)
  end, {
    bar = false,
    desc = "Send direct input to the active Codex chat",
    nargs = "*",
  })

  local function create_short_alias(name, callback, command_options)
    if vim.fn.exists(":" .. name) ~= 0 then
      notify("Did not create :" .. name .. " because that command is already in use", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_create_user_command(name, callback, command_options)
  end

  create_short_alias("CoLS", function()
    M.list()
  end, {
    desc = "Short alias for :CodexList",
  })

  create_short_alias("CoCh", function(command)
    M.chat(command.args)
  end, {
    bar = false,
    desc = "Short alias for :CodexChat",
    nargs = "*",
  })

  create_short_alias("CoSe", function(command)
    M.send_range(command.line1, command.line2)
  end, {
    bar = true,
    desc = "Short alias for :CodexSend",
    range = true,
  })
end

return M
