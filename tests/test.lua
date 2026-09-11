local root = assert(vim.env.CODEX_NVIM_TEST_ROOT)
local socket_path = assert(vim.env.CODEX_NVIM_TEST_SOCKET)
local codex_command = assert(vim.env.CODEX_NVIM_TEST_CODEX)
local state_path = assert(vim.env.CODEX_NVIM_TEST_STATE)

vim.opt.runtimepath:append(root)
vim.cmd("runtime plugin/codex.lua")

local codex = require("codex")
assert(codex.setup({
  auto_start = false,
  codex_command = codex_command,
  progress = { delay_ms = 0, interval_ms = 25, success_duration_ms = 50 },
  selection = { persist = true, state_path = state_path },
  socket_path = socket_path,
}) == codex)

for _, command in ipairs({ "CodexList", "CodexLS", "CodexSend", "CodexChat", "CoLS", "CoSe", "CoCh" }) do
  assert(vim.fn.exists(":" .. command) == 2, "missing command: " .. command)
end

local function upvalue(fn, expected_name)
  for index = 1, 12 do
    local name, value = debug.getupvalue(fn, index)
    if name == expected_name then
      return value
    end
  end
end

local state = assert(upvalue(codex.selected_chat, "state"))
state.selected_thread = { id = "thr_test", name = "Test chat" }

local sent = false
codex.send(string.rep("x", 70000), function(err, turn)
  assert(not err, err)
  assert(turn.id == "turn_test")
  sent = true
end)
assert(vim.wait(3000, function()
  return sent
end, 20), "timed out waiting for the fake App Server")

local sent_text
codex.send = function(text, callback)
  sent_text = text
  callback(nil, { id = "turn_local" })
end

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
vim.cmd("2,3CoSe")
assert(sent_text == "two\nthree", vim.inspect(sent_text))

vim.cmd([[CoCh literal | "quoted" []{}$#@!]])
assert(sent_text == [[literal | "quoted" []{}$#@!]], vim.inspect(sent_text))
assert(codex.status() == " ·   Input sent", codex.status())
assert(vim.wait(300, function()
  return codex.status() == ""
end, 10), codex.status())

local persist_selection = assert(upvalue(codex.clear_selection, "persist_selection"))
state.selected_thread = { id = "thr_saved", name = "Saved chat" }
persist_selection()
local stored = vim.json.decode(table.concat(vim.fn.readfile(state_path), "\n"))
assert(stored.selections[vim.fn.getcwd(0)].id == "thr_saved")
state.selected_thread = nil
state.selection_restored_path = nil
codex.setup({ selection = { persist = true, state_path = state_path } })
assert(codex.selected_chat_id() == "thr_saved")
codex.clear_selection()

print("codex.nvim tests passed")
