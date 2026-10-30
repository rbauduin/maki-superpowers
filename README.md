# Superpowers for Maki

A Maki port of [obra/superpowers](https://github.com/obra/superpowers)'s
OpenCode plugin.

It does two things:

1. Makes every Superpowers skill available through Maki's native `skill`
   tool.
2. Injects the `using-superpowers` bootstrap into the main agent's system
   prompt, with a tool mapping that translates Superpowers instructions to
   Maki's tools.

Subagent sessions (`research` and `general`) do **not** receive the
bootstrap, matching the OpenCode plugin's child-session guard.

## Requirements

- [Maki](https://maki.sh/) 0.6.5 or newer.
- A checkout of [obra/superpowers](https://github.com/obra/superpowers).
- `ln` from coreutils (Linux/macOS). On Windows, see
  [Windows](#windows).

## Installation

There are two ways to install this plugin:

- **As a Maki package** — recommended if you publish this directory as a git
  repository. Maki clones it, locks the commit, and asks for permissions.
- **Manually in the Maki config directory** — for a local checkout or when
  you prefer to run `init.lua` directly.

Both need a Superpowers checkout.

### 1. Get a Superpowers checkout

The plugin does not vendor Superpowers. Clone it somewhere stable:

```bash
git clone https://github.com/obra/superpowers.git ~/.config/maki/superpowers
```

Any location works. If you already installed the OpenCode plugin, its
checkout at `~/.config/opencode/superpowers` is detected automatically, so
you can skip this step. If the checkout is elsewhere, set `SUPERPOWERS_DIR`
(see [Configuration](#configuration)).

### 2a. Install as a Maki package (recommended for a git repo)

Push this directory to a git repository, then declare it in the global
`init.lua` (`~/.config/maki/init.lua`):

```lua
maki.pack.add({
  "https://github.com/<you>/maki-superpowers",
})
```

Restart Maki. Approve the permission prompt; the package requests
`fs_read`, `fs_write`, `run`, and `env`. Maki clones the repository and loads
`plugin/superpowers.lua`.

To update it later:

```
/packupdate maki-superpowers
```

To remove it, first delete the `maki.pack.add` entry, `/reload`, then:

```
/packdel maki-superpowers
```

The skill links under `<maki-config>/skills/` remain after removal; delete
them with `rm -f <maki-config>/skills/superpowers-*`.

For a local checkout, copy this directory into a hand-installed package slot
(Maki's data directory is `~/.local/share/maki` on Linux):

```bash
mkdir -p ~/.local/share/maki/site/pack/local/start
cp -r /path/to/maki-superpowers \
  ~/.local/share/maki/site/pack/local/start/maki-superpowers
```

A hand-installed `start` package loads at startup and Maki grants exactly the
permissions in its `plugin.toml`, with no approval prompt.

### 2b. Install in the config directory (manual)

The repository also supports the manual Maki config layout:

```
plugin/superpowers.lua  package entry (used by maki.pack.add)
lua/superpowers.lua     the plugin module
plugin.toml             permission grants
init.lua                config-directory loader (manual install only)
```

**Fresh Maki config** (no existing `init.lua` or `plugin.toml`):

```bash
REPO=/path/to/maki-superpowers
mkdir -p ~/.config/maki/lua
cp "$REPO/lua/superpowers.lua" ~/.config/maki/lua/
cp "$REPO/init.lua" ~/.config/maki/init.lua
cp "$REPO/plugin.toml" ~/.config/maki/plugin.toml
```

**Existing Maki config** — merge instead of overwriting:

```bash
REPO=/path/to/maki-superpowers
mkdir -p ~/.config/maki/lua
cp "$REPO/lua/superpowers.lua" ~/.config/maki/lua/
```

Append the loader to `~/.config/maki/init.lua`:

```lua
require("superpowers")
```

Add the permissions to `~/.config/maki/plugin.toml`. If the file already has
a `[permissions]` table, add only the missing keys; do not add a second
`[permissions]` table:

```toml
min_maki_version = "0.6.5"

[permissions]
fs_read = true
fs_write = true
run = true
env = true
```

`env` is optional. Without it the plugin simply ignores
`SUPERPOWERS_DIR` / `SUPERPOWERS_ROOT` and uses the auto-detected paths.
`run` and `fs_write` are needed to create the skill symlinks.

If `~/.maki/` exists, Maki reads it **instead of** `~/.config/maki/`. Put the
files in whichever directory Maki actually uses. On Windows the config
directory is `%APPDATA%\maki\`.

### 3. Reload

Run `/reload` in Maki, or start a new session.

Check that it loaded:

```bash
maki prompt | grep -n "EXTREMELY_IMPORTANT"
maki prompt --tools | grep -n "brainstorming"
```

The first command should print the start of the injected bootstrap. The
second should show the Superpowers skills in the `skill` tool description
(after the first run has created the links).

## Usage

Start a session normally. The bootstrap makes the agent check for a relevant
skill before acting. You can also ask explicitly:

```
Use the brainstorming skill for this feature.
Use the systematic-debugging skill to track down this bug.
```

The skills are listed by Maki's native `skill` tool. Names are the bare
Superpowers names, for example:

- `brainstorming`
- `systematic-debugging`
- `test-driven-development`
- `writing-plans`
- `executing-plans`
- `subagent-driven-development`
- `requesting-code-review`
- `receiving-code-review`
- `verification-before-completion`
- `using-git-worktrees`
- `finishing-a-development-branch`
- `dispatching-parallel-agents`
- `writing-skills`
- `diagnosing-superpowers`
- `using-superpowers`

Do not load `using-superpowers` manually; its content is already in the
system prompt.

### Commands

| Command | Description |
|---|---|
| `/superpowers` | Show the detected checkout, number of skills, and link status. |
| `/superpowers refresh` | Re-scan the checkout and recreate the skill links. The bootstrap is re-read too, so a `/reload` is not needed. |

## Configuration

The plugin looks for a checkout in this order:

1. `$SUPERPOWERS_DIR`
2. `$SUPERPOWERS_ROOT`
3. `<maki-config>/superpowers`
4. `~/.config/superpowers`
5. `~/.config/opencode/superpowers`
6. `~/.claude/plugins/superpowers`
7. `~/.superpowers`
8. `~/superpowers`
9. `<cwd>/.maki/superpowers`
10. `<cwd>/.superpowers`

A valid checkout has a `skills/` directory with `using-superpowers/SKILL.md`
in it. Pointing `SUPERPOWERS_DIR` directly at the `skills/` directory also
works.

The plugin creates links named `superpowers-<skill-directory>` in
`<maki-config>/skills/`. Maki's `skill` tool scans that directory on every
call and follows symlinks. Links whose source skill no longer exists are
removed automatically.

## How it works

- **Skills** — Maki has no plugin API for registering skills, so the plugin
  links each Superpowers skill directory into Maki's scanned skills
  directory. The skill's frontmatter supplies its name and description.
- **Bootstrap** — registered with `maki.api.register_prompt_hint` in the
  `after_instructions` slot, for the `system` prompt only. Subagents use the
  `research` and `general` prompts, so they are excluded structurally
  rather than by model compliance.
- **Lazy start** — Maki loads `init.lua` in a synchronous chunk, where
  filesystem calls fail with `attempt to yield across metamethod/C-call
  boundary`. The plugin therefore registers its hint and command at load
  time and does all filesystem and link work inside the hint callback (and
  the `/superpowers` handlers), which run in a yieldable context.
- **First run** — Maki's builtin `skill` tool builds its description before
  user plugins load. When the links were not already present at startup, the
  bootstrap includes the skill list so the names are still visible on the
  very first turn. Later runs rely on the native list.

## Troubleshooting

**Nothing appears in the prompt**

- For a package install, confirm the `maki.pack.add` entry is present and
  the package loaded. For a manual install, confirm
  `require("superpowers")` is in the active `init.lua`.
- Confirm the active `plugin.toml` grants `fs_read`.
- Check the log: `~/.local/logs/maki/maki.log` on Linux.
  Set `MAKI_LOG=debug` for more detail.
- Run `maki prompt | grep EXTREMELY_IMPORTANT`.

**Skills are not in the `skill` tool**

- Run `/superpowers` to see whether a checkout was found.
- Run `/superpowers refresh`, then start a new session.
- Make sure `ln` is available and the plugin has `run` and `fs_write`
  permissions.
- The bootstrap still lists the skills on a failed link, and instructs the
  model to read `<root>/skills/<name>/SKILL.md` directly.

**Wrong checkout is used**

Set `SUPERPOWERS_DIR` explicitly. Earlier entries in the detection order win,
so a stale `~/.config/maki/superpowers` beats
`~/.config/opencode/superpowers`.

**Changes to a skill are not picked up**

Skills are read fresh by the `skill` tool on every call. The bootstrap is
cached for the session; run `/superpowers refresh` to rebuild it.

### Windows

The plugin uses `ln -sfn`, so native skill links require an environment where
`ln` exists (for example WSL or Git Bash). Without it, linking fails
gracefully: the bootstrap still contains the skill list and tells the model
to read `SKILL.md` files directly from the checkout. You can also create
directory junctions manually under `%APPDATA%\maki\skills\`.

## Uninstall

**Package install:**

1. Remove the `maki.pack.add` entry from the global `init.lua` and `/reload`.
2. Run `/packdel maki-superpowers`.
3. Delete the links: `rm -f ~/.config/maki/skills/superpowers-*`

**Manual install:**

1. Remove `require("superpowers")` from `~/.config/maki/init.lua`.
2. Delete `~/.config/maki/lua/superpowers.lua`.
3. Delete the links: `rm -f ~/.config/maki/skills/superpowers-*`
4. Optionally remove the permissions from `~/.config/maki/plugin.toml`.

A hand-installed package slot can simply be deleted from
`<maki-data>/site/pack/`.

## Credits

- [obra/superpowers](https://github.com/obra/superpowers) — the skills,
  methodology, and the OpenCode plugin this port follows.
- [Maki](https://maki.sh/) — the host agent and Lua plugin API.

The Superpowers skills and the upstream OpenCode plugin remain under their
own license; see the [upstream repository](https://github.com/obra/superpowers).
