-- Superpowers for Maki.
--
-- Port of obra/superpowers' OpenCode plugin:
--   1. exposes every <root>/skills/<name>/SKILL.md through Maki's native
--      `skill` tool, by linking each skill directory into
--      <maki-config>/skills/ (Maki rescans that directory on every call);
--   2. injects the using-superpowers bootstrap into the main agent's system
--      prompt. Targeting prompt = "system" mirrors the OpenCode plugin's
--      child-session guard: research/general subagent prompts never see it.
--
-- Point the plugin at a checkout with SUPERPOWERS_DIR (or SUPERPOWERS_ROOT).
-- Without it the usual checkout locations are probed, including
-- ~/.config/opencode/superpowers.

local USING_SKILL = "using-superpowers"
local SKILL_FILE = "SKILL.md"
local LINK_PREFIX = "superpowers-"

local M = {}

local function join(...)
  return maki.fs.joinpath(...)
end

local function is_dir(path)
  local ok, meta = pcall(maki.fs.metadata, path)
  return ok and meta ~= nil and meta.is_dir == true
end

local function read_text(path)
  local ok, content = pcall(maki.fs.read, path)
  if ok and type(content) == "string" then
    return content
  end
  return nil
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function getenv(name)
  -- pcall is safe here: os_getenv is synchronous. It lets the plugin run
  -- without the env permission, falling back to the default locations.
  local ok, value = pcall(maki.uv.os_getenv, name)
  if ok and type(value) == "string" and value ~= "" then
    return value
  end
end

local function normalize(path)
  local ok, value = pcall(maki.fs.normalize, path)
  if ok and type(value) == "string" then
    return value
  end
  return path
end

local function candidate_roots()
  local roots = {}
  local seen = {}
  local function add(path)
    if not path then
      return
    end
    path = normalize(path)
    if not seen[path] then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end

  add(getenv("SUPERPOWERS_DIR"))
  add(getenv("SUPERPOWERS_ROOT"))

  local config
  local home
  local cwd
  local config_ok, config_value = pcall(maki.env.config_dir)
  if config_ok then
    config = config_value
  end
  local home_ok, home_value = pcall(maki.uv.os_homedir)
  if home_ok then
    home = home_value
  end
  local cwd_ok, cwd_value = pcall(maki.uv.cwd)
  if cwd_ok then
    cwd = cwd_value
  end

  if config then
    add(join(config, "superpowers"))
  end
  if home then
    add(join(home, ".config", "superpowers"))
    add(join(home, ".config", "opencode", "superpowers"))
    add(join(home, ".claude", "plugins", "superpowers"))
    add(join(home, ".superpowers"))
    add(join(home, "superpowers"))
  end
  if cwd then
    add(join(cwd, ".maki", "superpowers"))
    add(join(cwd, ".superpowers"))
  end

  return roots
end

local function find_root()
  local fallback
  for _, candidate in ipairs(candidate_roots()) do
    -- Accept a checkout root or a direct path to its skills/ directory.
    local root = candidate
    if not is_dir(join(root, "skills")) and maki.fs.basename(root) == "skills" then
      root = maki.fs.dirname(root)
    end
    if is_dir(join(root, "skills")) then
      fallback = fallback or root
      if read_text(join(root, "skills", USING_SKILL, SKILL_FILE)) then
        return root
      end
    end
  end
  return fallback
end

local function parse_frontmatter(content)
  local block = content:match("^%-%-%-[ \t]*\r?\n(.-)\r?\n%-%-%-")
  if not block then
    return {}
  end

  local ok, decoded = pcall(maki.yaml.decode, block)
  if ok and type(decoded) == "table" then
    return decoded
  end

  -- Minimal fallback for frontmatter Maki's YAML parser rejects.
  local fm = {}
  fm.name = block:match("^name:%s*(.-)%s*$") or block:match("\nname:%s*(.-)%s*$")
  fm.description = block:match("^description:%s*(.-)%s*$")
    or block:match("\ndescription:%s*(.-)%s*$")
  for key, value in pairs(fm) do
    fm[key] = trim(value:gsub('^(["\'])(.*)%1$', "%2"))
  end
  return fm
end

local function strip_frontmatter(content)
  local s = content
  if s:sub(1, 3) == "\239\187\191" then
    s = s:sub(4)
  end
  local body = s:match("^%-%-%-[ \t]*\r?\n.-\r?\n%-%-%-[ \t]*\r?\n?(.*)$")
  if body then
    return body
  end
  return s
end

local function discover_skills(root)
  local skills = {}
  local ok, entries = pcall(maki.fs.dir, join(root, "skills"))
  if not ok or not entries then
    return skills
  end

  for _, entry in ipairs(entries) do
    local dir = entry[1]
    local kind = entry[2]
    if dir and (kind == "directory" or kind == "link") then
      local path = join(root, "skills", dir, SKILL_FILE)
      local content = read_text(path)
      if content then
        local fm = parse_frontmatter(content)
        local has_name = type(fm.name) == "string" and fm.name ~= ""
        local name = has_name and fm.name or dir
        local description = fm.description
        if type(description) ~= "string" then
          description = ""
        end
        skills[#skills + 1] = {
          dir = dir,
          name = name,
          -- Without frontmatter, Maki names the skill after its directory,
          -- which is the prefixed link name, not the checkout directory.
          tool_name = has_name and name or (LINK_PREFIX .. dir),
          description = trim(description),
          path = path,
        }
      end
    end
  end

  table.sort(skills, function(a, b)
    return a.name < b.name
  end)
  return skills
end

local function run_ln(source, destination)
  local started, id, start_err = pcall(maki.fn.jobstart, { "ln", "-sfn", source, destination }, {
    stdout = false,
    stderr = false,
    scope = "plugin",
  })
  if not started then
    return nil, id
  end
  if not id then
    return nil, start_err
  end

  local waited, result, wait_err = pcall(maki.fn.jobwait, id, 5000)
  if not waited then
    return nil, result
  end
  if not result then
    return nil, wait_err
  end
  if result.exit_code ~= 0 then
    pcall(maki.fn.jobstop, id)
    return nil, "ln exited " .. tostring(result.exit_code)
  end
  return true
end

local function skills_dir()
  local ok, config = pcall(maki.env.config_dir)
  if not ok or not config then
    return nil
  end
  return join(config, "skills")
end

-- True when every link from an earlier run is already on disk. Maki's
-- builtin skill tool scans at load time, so it already saw them on this
-- start; otherwise the bootstrap has to spell the names out itself.
local function all_links_present(dir, skills)
  if not dir or #skills == 0 then
    return false
  end
  -- Read through the links rather than trusting the directory entries: a
  -- link left by an earlier run can point at a checkout that has since moved.
  for _, skill in ipairs(skills) do
    if not read_text(join(dir, LINK_PREFIX .. skill.dir, SKILL_FILE)) then
      return false
    end
  end
  return true
end

local function sync_links(root, skills)
  local dir = skills_dir()
  if not dir then
    return 0, { "no maki config dir" }
  end
  if not is_dir(dir) then
    local called, created, err = pcall(maki.fs.mkdir, dir, { parents = true })
    if not called or not created then
      return 0, { "create " .. dir .. ": " .. tostring(called and err or created) }
    end
  end

  local exe_ok, ln_path = pcall(maki.fn.executable, "ln")
  if not exe_ok or not ln_path then
    return 0, { "ln not available; set run = true and install coreutils" }
  end

  local desired = {}
  for _, skill in ipairs(skills) do
    desired[LINK_PREFIX .. skill.dir] = join(root, "skills", skill.dir)
  end

  local ok, entries = pcall(maki.fs.dir, dir)
  if ok and entries then
    for _, entry in ipairs(entries) do
      local name = entry[1]
      if
        type(name) == "string"
        and name:sub(1, #LINK_PREFIX) == LINK_PREFIX
        and not desired[name]
      then
        pcall(maki.fs.rm, join(dir, name), { force = true })
      end
    end
  end

  local linked = 0
  local failures = {}
  for name, target in pairs(desired) do
    local ok, err = run_ln(target, join(dir, name))
    if ok then
      linked = linked + 1
    else
      failures[#failures + 1] = name .. ": " .. tostring(err)
    end
  end
  return linked, failures
end

local TOOL_MAPPING = [[**Tool Mapping for Maki:**
When a Superpowers skill names another harness's tool, substitute the Maki equivalent:

- Create or update todos -> `todo_write`
- `Subagent (general-purpose):` / the Task tool -> `task` with `subagent_type: "general"` (pass `description` and `prompt`; use `"research"` for read-only exploration). Maki has no subagent continuation id: start a fresh subagent with the full context instead.
- Invoke a skill -> Maki's native `skill` tool
- Read files -> `read` (use `index` first on large files)
- Create or edit files -> `write`, `edit`, `multiedit`, `edit_lines`
- Delete a file or directory -> `bash` with `rm` (ask first when destructive)
- Run shell commands -> `bash` (`command`, `workdir`, `timeout`, `background`)
- Read background shell output -> the result arrives as a message when the job ends; run a follow-up `bash` if you need more.
- Search file contents -> `grep`
- Find files by name -> `glob`
- List a directory -> `list`
- Fetch a URL -> `webfetch`
- Search the web -> `websearch`
- Ask the user a question -> `question`
- Enter or exit plan mode -> Maki's plan mode is a user-controlled session mode; ask the user to switch modes. Do not claim a tool call did it.
- Slash commands -> Maki has no model-callable slash command tool; follow the command's text inline or ask the user to run it.]]

local function build_bootstrap(root, skills, include_list)
  local content = read_text(join(root, "skills", USING_SKILL, SKILL_FILE))
  if not content then
    return nil, "missing " .. join(root, "skills", USING_SKILL, SKILL_FILE)
  end

  local parts = {
    "\n\n<EXTREMELY_IMPORTANT>",
    "You have superpowers.",
    "",
    '**IMPORTANT: The using-superpowers skill content is included below. It is ALREADY LOADED - you are currently following it. Do NOT use the skill tool to load "using-superpowers" again - that would be redundant.**',
    "",
    strip_frontmatter(content):gsub("^%s+", ""):gsub("%s+$", ""),
    "",
    TOOL_MAPPING,
    "",
    "Superpowers root: `" .. root .. "`",
  }

  if include_list and #skills > 0 then
    parts[#parts + 1] = ""
    parts[#parts + 1] = "**Superpowers skills available here. Load one with the `skill` tool:**"
    for _, skill in ipairs(skills) do
      local line = "- " .. skill.tool_name
      if skill.description ~= "" then
        line = line .. ": " .. skill.description
      end
      parts[#parts + 1] = line
    end
    parts[#parts + 1] = ""
    parts[#parts + 1] = "If the `skill` tool does not list a skill yet, read `<root>/skills/<skill-name>/"
      .. SKILL_FILE
      .. "` directly."
  end

  parts[#parts + 1] = "</EXTREMELY_IMPORTANT>"
  return table.concat(parts, "\n")
end

local function describe(root, skills, linked, failures)
  if not root then
    return "Superpowers not found. Clone obra/superpowers and set SUPERPOWERS_DIR (or put it at ~/.config/maki/superpowers)."
  end
  local text = string.format(
    "Superpowers: %d skills from %s; %d linked into %s",
    #skills,
    root,
    linked or 0,
    skills_dir() or "?"
  )
  if failures and #failures > 0 then
    text = text .. "; link failures: " .. table.concat(failures, ", ")
  end
  return text
end

local state = {
  ready = false,
  root = nil,
  skills = {},
  linked = 0,
  failures = {},
  bootstrap = nil,
  err = nil,
}

-- Runs inside the prompt-hint callback or a command handler, both of which
-- allow Maki's async filesystem calls. It must never run at plugin load:
-- init.lua is a synchronous chunk, so an fs call there fails with
-- "attempt to yield across metamethod/C-call boundary".
local function ensure_ready(force)
  if state.ready and not force and state.bootstrap then
    return state.bootstrap
  end

  state.root = find_root()
  state.skills = {}
  state.linked = 0
  state.failures = {}
  state.bootstrap = nil
  state.err = nil

  if not state.root then
    state.err = "no checkout found; clone obra/superpowers and set SUPERPOWERS_DIR"
    maki.log.warn("[superpowers] " .. state.err)
    return nil
  end

  local skills = discover_skills(state.root)
  local all_present = all_links_present(skills_dir(), skills)
  local linked, failures = sync_links(state.root, skills)

  -- Maki's builtin skill tool built its description before this plugin
  -- loaded. On the first run the Superpowers names are therefore absent
  -- from it, so spell them out in the bootstrap. Later runs already have
  -- the full list in the tool description.
  local include_list = not all_present or #failures > 0
  local bootstrap, err = build_bootstrap(state.root, skills, include_list)

  state.ready = true
  state.skills = skills
  state.linked = linked
  state.failures = failures
  state.bootstrap = bootstrap
  state.err = err

  if not bootstrap then
    maki.log.warn("[superpowers] " .. tostring(err))
    return nil
  end

  maki.log.info(string.format(
    "[superpowers] root=%s skills=%d linked=%d failures=%d",
    state.root,
    #skills,
    linked,
    #failures
  ))
  for _, failure in ipairs(failures) do
    maki.log.warn("[superpowers] link failed: " .. failure)
  end
  return bootstrap
end

local function status_text()
  ensure_ready(false)
  return describe(state.root, state.skills, state.linked, state.failures)
end

local function refresh(verbose)
  local bootstrap = ensure_ready(true)
  if verbose then
    maki.ui.flash(status_text())
  end
  return bootstrap
end

-- A function, not a string: the first call happens inside a yieldable
-- context, which is what makes the filesystem work above possible. Targeting
-- prompt = "system" is the structural equivalent of the OpenCode plugin's
-- child-session guard: research/general subagent prompts never see it.
maki.api.register_prompt_hint({
  slot = "after_instructions",
  prompt = "system",
  content = function()
    return ensure_ready(false) or ""
  end,
})

maki.api.register_command({
  name = "/superpowers",
  description = "Show Superpowers status, or refresh skill links with /superpowers refresh.",
  nargs = "?",
  handler = function(opts)
    local arg = trim(opts.args or "")
    if arg == "refresh" then
      refresh(false)
      maki.ui.flash("Superpowers links refreshed: " .. status_text())
    else
      maki.ui.flash(status_text())
    end
  end,
})

M.find_root = find_root
M.discover_skills = discover_skills
M.ensure_ready = ensure_ready
M.refresh = refresh
M.status = status_text

return M
