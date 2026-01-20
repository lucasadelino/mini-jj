# JJTrack

JJTrack is a Neovim plugin that tracks data about the current
[Jujutsu](https://www.jj-vcs.dev/latest/)
commit and saves it to buffer-local variables. You can then use these variables
in a statusline or wherever else you like.

The following
[commit properties](https://docs.jj-vcs.dev/latest/templates/#commit-type)
are tracked:

- The current change_id (separated into prefix and rest)
- The current commit_id (separated into prefix and rest)
- The following boolean properties:
  - `conflict`
  - `divergent`
  - `empty`
  - `hidden`
  - `immutable`
  - `mine`
  - `root`
- The local and remote bookmarks of the current commit

This plugin is basically a subset of
[mini.git](https://github.com/nvim-mini/mini-git),
with most of the non-tracking features (e.g. the `:Git` command; history
helper functions) removed, and the tracking features adapted to JJ. Huge thanks
to [Evgeni Chasnovski](https://github.com/echasnovski) 
and the mini.nvim contributors for their work!

## Installation
Install JJTrack with your favorite plugin manager. For instance, with
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "lucasadelino/jjtrack",
  config = function()
    require('jjtrack').setup()
  end
}
```

## Usage
TLDR: Use the `vim.b.jjtrack_summary` variable.

As mentioned previously, the data-fetching logic of this plugin is pretty much
identical to mini.git. The gist of it is that the plugin checks whether the
current buffer belongs to a Git repo. If it does, the plugin stars to
automatically fetch JJ data after every change to the repo's `.git` directory
(with a configurable debounce), which it saves to the `vim.b.jjtrack_summary`
variable. This variable is a table, containing the JJ commit properties listed
above.

### Example
Here's an example function that retrieves the change_id prefix and rest,
returning a string where the prefix is emphasized (similar to how JJ shows it
by default):

```lua
local function jj_change()
  local jj_summary = vim.b.jjtrack_summary
  local prefix, rest

  if jj_summary then
    prefix = vim.b.jjtrack_summary.change_id_prefix
    rest = vim.b.jjtrack_summary.change_id_rest
  end

  if prefix and rest then
    prefix = string.format('%%#Special#%s', prefix)
    rest = string.format('%%#Comment#%s%%#Normal#', rest)
    return prefix .. rest
  else return ''
  end

end
```

You can also retrieve the data for a given buffer by calling the
`get_buf_data()` function, like so:

```lua
local jj = require('jjtrack')
jj.get_buf_data(3) -- sub the appropriate buffer number here
```

## Preemptive FAQs
Here are a couple of design decisions made on this project. Neither of them are
set in stone; PRs are welcome if you disagree or if you can think of a use
case they don't allow for.

### Why not watch the .jj repo, rather than the .git repo?
Because why would you, at this point? As of writing this, Git is the only
backend supported by JJ, the native backend is still a WIP. The `.git`
directory is easier to watch non-recursively, and should trigger JJTrack
updates after most JJ operations. Obviously this can change in the future, but
we can cross that bridge when we get there.

### Why not track JJ diff stats, like mini.git does?
Because I'm assuming you don't exclusively use JJ; that, at least _sometimes_,
you work with plain Git repos. This seems like a reasonable assumption. In this
case, you probably already have a plugin to give you diff stats (like mini.git
or [gitsigns](https://github.com/lewis6991/gitsigns.nvim)), so why not just
continue to use it for the diff stats? That way you can always show them,
without having to check if you're in a Git or a JJ repo since it'll work on
both. I'd prefer to keep this plugin simple, focusing on retrieving data you
wouldn't already have.
