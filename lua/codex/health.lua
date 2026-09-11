local M = {}

local function format_version(version)
  return table.concat(version, ".")
end

local function at_least(actual, minimum)
  for index = 1, #minimum do
    local part = actual[index] or 0
    if part ~= minimum[index] then
      return part > minimum[index]
    end
  end
  return true
end

local function parse_version(output)
  local major, minor, patch = output:match("(%d+)%.(%d+)%.(%d+)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function check_nvim(info)
  local version = vim.version()
  local actual = { version.major, version.minor, version.patch }
  if at_least(actual, info.minimum_nvim_version) then
    vim.health.ok("NeoVim " .. format_version(actual) .. " meets the minimum requirement")
  else
    vim.health.error(
      "NeoVim " .. format_version(actual) .. " is too old",
      "Install NeoVim " .. format_version(info.minimum_nvim_version) .. " or newer."
    )
  end
end

local function check_codex_cli(info)
  if vim.fn.executable(info.codex_command) ~= 1 then
    vim.health.error(
      "Codex CLI command is not executable: " .. info.codex_command,
      "Install Codex CLI " .. format_version(info.minimum_codex_version) .. " or newer, or set codex_command."
    )
    return
  end

  local result = vim.system({ info.codex_command, "--version" }, { text = true }):wait()
  if result.code ~= 0 then
    vim.health.error(
      "Could not run " .. info.codex_command .. " --version",
      vim.trim(result.stderr or result.stdout or "")
    )
    return
  end

  local version = parse_version(result.stdout or "")
  if not version then
    vim.health.error("Could not parse the Codex CLI version", vim.trim(result.stdout or ""))
  elseif at_least(version, info.minimum_codex_version) then
    vim.health.ok("Codex CLI " .. format_version(version) .. " meets the minimum requirement")
  else
    vim.health.error(
      "Codex CLI " .. format_version(version) .. " is too old",
      "Install Codex CLI " .. format_version(info.minimum_codex_version) .. " or newer."
    )
  end
end

local function check_socket(info)
  local stat = vim.uv.fs_stat(info.socket_path)
  if stat and stat.type == "socket" then
    vim.health.ok("Codex App Server socket is available: " .. info.socket_path)
  else
    vim.health.warn(
      "Codex App Server socket is not available: " .. info.socket_path,
      "Run `codex app-server daemon start`, or let codex.nvim start it on first use."
    )
  end
end

local function check_selection_state(info)
  if not info.selection_persist then
    vim.health.info("Per-project chat selection persistence is disabled")
    return
  end

  local path = info.selection_state_path
  local directory = vim.fs.dirname(path)
  if vim.fn.filereadable(path) == 1 and vim.fn.filewritable(path) == 1 then
    vim.health.ok("Persistent chat-selection state is writable: " .. path)
  elseif vim.uv.fs_stat(directory) then
    vim.health.ok("Persistent chat-selection directory is available: " .. directory)
  else
    vim.health.info("Persistent chat-selection directory will be created on first selection: " .. directory)
  end
end

local function check_commands()
  local commands = { "CodexList", "CodexLS", "CodexSend", "CodexChat", "CoLS", "CoSe", "CoCh" }
  local missing = {}
  for _, command in ipairs(commands) do
    if vim.fn.exists(":" .. command) == 0 then
      missing[#missing + 1] = command
    end
  end

  if #missing == 0 then
    vim.health.ok("Codex commands and short aliases are registered")
  else
    vim.health.warn("Some Codex commands are unavailable: " .. table.concat(missing, ", "))
  end
end

function M.check()
  local info = require("codex")._health_info()
  vim.health.start("codex.nvim " .. info.plugin_version)
  check_nvim(info)
  check_codex_cli(info)
  check_socket(info)
  check_selection_state(info)
  check_commands()
end

return M
