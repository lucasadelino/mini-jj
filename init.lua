-- Module definition ==========================================================
local MiniJJ = {}
local H = {}

--- Module setup
---
--- Besides general side effects (see |mini.nvim|), it also:
--- - Sets up auto enabling in every normal buffer for an actual file on disk.
--- - Creates |:Git| command.
---
---@param config table|nil Module config table. See |MiniJJ.config|.
---
---@usage >lua
---   require('mini.git').setup() -- use default config
---   -- OR
---   require('mini.git').setup({}) -- replace {} with your config table
--- <
MiniJJ.setup = function(config)
  -- Export module
  _G.MiniJJ = MiniJJ

  -- Setup config
  config = H.setup_config(config)

  -- Apply config
  H.apply_config(config)

  -- Ensure proper Git executable
  local exec = config.job.jj_executable
  H.has_git = vim.fn.executable(exec) == 1
  if not H.has_git then H.notify('There is no `' .. exec .. '` executable', 'WARN') end

  -- Define behavior
  H.create_autocommands()
  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    H.auto_enable({ buf = buf_id })
  end
end

--stylua: ignore
--- Defaults ~
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
---@text # Job ~
---
--- `config.job` contains options for customizing CLI executions.
---
--- `job.jj_executable` defines a full path to Git executable. Default: "jj".
---
--- `job.timeout` is a duration (in ms) from job start until it is forced to stop.
--- Default: 30000.
---
--- # Command ~
---
--- `config.command` contains options for customizing |:Git| command.
---
--- `command.split` defines default split direction for |:Git| command output. Can be
--- one of "horizontal", "vertical", "tab", or "auto". Value "auto" uses |:vertical|
--- if only 'mini.git' buffers are shown in the tabpage and |:tab| otherwise.
--- Default: "auto".
MiniJJ.config = {
  -- General CLI execution
  job = {
    -- Path to Git executable
    jj_executable = 'jj',

    -- Timeout (in ms) for each job before force quit
    timeout = 30000,
  },

}
--minidoc_afterlines_end

--- Enable Git tracking in a file buffer
---
--- Tracking is done by reacting to changes in file content or file's repository
--- in the form of keeping buffer data up to date. The data can be used via:
--- - |MiniJJ.get_buf_data()|. See its help for a list of actually tracked data.
--- - `vim.b.minijj_summary` (table) and `vim.b.minijj_summary_string` (string)
---   buffer-local variables which are more suitable for statusline.
---   `vim.b.minijj_summary_string` contains information about HEAD, file status,
---   and in progress action (see |MiniJJ.get_buf_data()| for more details).
---   See |MiniJJ-examples| for how it can be tweaked and used in statusline.
---
--- Note: this function is called automatically for all new normal buffers.
--- Use it explicitly if buffer was disabled.
---
--- `User` event `MiniJJUpdated` is triggered whenever tracking data is updated.
--- Note that not all data listed in |MiniJJ.get_buf_data()| can be present (yet)
--- at the point of event being triggered.
---
---@param buf_id __git_buf_id
MiniJJ.enable = function(buf_id)
  buf_id = H.validate_buf_id(buf_id)

  -- Don't enable more than once
  if H.is_buf_enabled(buf_id) or H.is_disabled(buf_id) or not H.has_git then return end

  -- Enable only in buffers which *can* be part of Git repo
  local path = H.get_buf_realpath(buf_id)
  if path == '' or vim.fn.filereadable(path) ~= 1 then return end

  -- Start tracking
  H.cache[buf_id] = {}
  H.setup_buf_behavior(buf_id)
  H.start_tracking(buf_id, path)
end

--- Disable Git tracking in buffer
---
---@param buf_id __git_buf_id
MiniJJ.disable = function(buf_id)
  buf_id = H.validate_buf_id(buf_id)

  local buf_cache = H.cache[buf_id]
  if buf_cache == nil then return end
  H.cache[buf_id] = nil
  --lel

  -- Cleanup
  pcall(vim.api.nvim_del_augroup_by_id, buf_cache.augroup)
  vim.b[buf_id].minijj_summary, vim.b[buf_id].minijj_summary_string = nil, nil

  -- - Unregister buffer from repo watching with possibly more cleanup
  local repo = buf_cache.repo
  if H.repos[repo] == nil then return end
  H.repos[repo].buffers[buf_id] = nil
  if vim.tbl_count(H.repos[repo].buffers) == 0 then
    H.teardown_repo_watch(repo)
    H.repos[repo] = nil
  end
end

--- Toggle Git tracking in buffer
---
--- Enable if disabled, disable if enabled.
---
---@param buf_id __git_buf_id
MiniJJ.toggle = function(buf_id)
  buf_id = H.validate_buf_id(buf_id)
  if H.is_buf_enabled(buf_id) then return MiniJJ.disable(buf_id) end
  return MiniJJ.enable(buf_id)
end

--- Get buffer data
---
---@param buf_id __git_buf_id
---
---@return table|nil Table with buffer Git data or `nil` if buffer is not enabled.
---   If the file is not part of Git repo, table will be empty.
---   Table has the following fields:
---   - <repo> `(string)` - full path to '.git' directory.
---   - <root> `(string)` - full path to worktree root.
---   - <head> `(string)` - full commit of current HEAD.
---   - <head_name> `(string)` - short name of current HEAD (like "master").
---     For detached HEAD it is "HEAD".
---   - <status> `(string)` - two character file status as returned by `git status`.
---     (bisect, merge, etc.). Can be a combination of those separated by ",".
MiniJJ.get_buf_data = function(buf_id)
  buf_id = H.validate_buf_id(buf_id)
  local buf_cache = H.cache[buf_id]
  if buf_cache == nil then return nil end
  return {
    repo = buf_cache.repo,
    root = buf_cache.root,
    head = buf_cache.head,
    head_name = buf_cache.head_name,
    -- status = buf_cache.status,
  }
end

-- Helper data ================================================================
-- Module default config
H.default_config = MiniJJ.config

-- Cache per enabled buffer. Values are tables with fields:
-- - <augroup> - identifier of augroup defining buffer behavior.
-- - <repo> - path to buffer's repo ('.git' directory).
-- - <root> - path to worktree root.
-- - <head> - full commit of `HEAD`.
-- - <head_name> - short name of `HEAD` (`'HEAD'` for detached head).
-- - <status> - current file status.
H.cache = {}

-- Cache per repo (git directory) path. Values are tables with fields:
-- - <fs_event> - `vim.loop` event for watching repo dir.
-- - <timer> - timer to debounce repo changes.
-- - <buffers> - map of buffers which should are part of repo.
H.repos = {}

-- Whether to temporarily skip some checks (like when inside `GIT_EDITOR`)
H.skip_timeout = false
H.skip_sync = false

-- Helper functionality =======================================================
-- Settings -------------------------------------------------------------------
H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('job', config.job, 'table')
  H.check_type('job.jj_executable', config.job.jj_executable, 'string')
  H.check_type('job.timeout', config.job.timeout, 'number')

  return config
end

H.apply_config = function(config) MiniJJ.config = config end

H.create_autocommands = function()
  local gr = vim.api.nvim_create_augroup('MiniJJ', {})

  local au = function(event, pattern, callback, desc)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = callback, desc = desc })
  end

  -- NOTE: Try auto enabling buffer on every `BufEnter` to not have `:edit`
  -- disabling buffer, as it calls `on_detach()` from buffer watcher
  au('BufEnter', '*', H.auto_enable, 'Enable Git tracking')
end

H.is_disabled = function(buf_id) return vim.g.minijj_disable == true or vim.b[buf_id or 0].minijj_disable == true end

-- Autocommands ---------------------------------------------------------------
H.auto_enable = vim.schedule_wrap(function(data)
  local buf = data.buf
  if not (vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].buflisted) then return end
  MiniJJ.enable(data.buf)
end)

-- Command --------------------------------------------------------------------
H.get_git_cwd = function()
  local buf_cache = H.cache[vim.api.nvim_get_current_buf()] or {}
  return buf_cache.root or vim.fn.getcwd()
end

-- Validators -----------------------------------------------------------------
H.validate_buf_id = function(x)
  if x == nil or x == 0 then return vim.api.nvim_get_current_buf() end
  if not (type(x) == 'number' and vim.api.nvim_buf_is_valid(x)) then
    H.error('`buf_id` should be `nil` or valid buffer id.')
  end
  return x
end

-- Enabling -------------------------------------------------------------------
H.is_buf_enabled = function(buf_id) return H.cache[buf_id] ~= nil and vim.api.nvim_buf_is_valid(buf_id) end

H.setup_buf_behavior = function(buf_id)
  local augroup = vim.api.nvim_create_augroup('MiniJJBuffer' .. buf_id, { clear = true })
  H.cache[buf_id].augroup = augroup

  vim.api.nvim_buf_attach(buf_id, false, {
    -- Called when buffer content is changed outside of current session
    -- Needed as otherwise `on_detach()` is called without later auto enabling
    on_reload = function()
      local buf_cache = H.cache[buf_id]
      if buf_cache == nil or buf_cache.root == nil then return end
      -- Don't upate repo/root as it is tracked in 'BufFilePost' autocommand
      H.update_git_head(buf_cache.root, { buf_id })
      -- Don't upate status as it is tracked in file watcher
    end,

    -- Called when buffer is unloaded from memory (`:h nvim_buf_detach_event`),
    -- **including** `:edit` command. Together with auto enabling it makes
    -- `:edit` command serve as "restart".
    on_detach = function() MiniJJ.disable(buf_id) end,
  })

  local reset_if_enabled = vim.schedule_wrap(function(data)
    if not H.is_buf_enabled(data.buf) then return end
    MiniJJ.disable(data.buf)
    MiniJJ.enable(data.buf)
  end)
  local bufrename_opts = { group = augroup, buffer = buf_id, callback = reset_if_enabled, desc = 'Reset on rename' }
  -- NOTE: `BufFilePost` does not look like a proper event, but it (yet) works
  vim.api.nvim_create_autocmd('BufFilePost', bufrename_opts)

  local buf_disable = function() MiniJJ.disable(buf_id) end
  local bufdelete_opts = { group = augroup, buffer = buf_id, callback = buf_disable, desc = 'Disable on delete' }
  vim.api.nvim_create_autocmd('BufDelete', bufdelete_opts)
end

-- Tracking -------------------------------------------------------------------
H.start_tracking = function(buf_id, path)
  local command = H.jj_cmd({ 'workspace', 'root' })

  -- If path is not in Git, disable buffer but make sure that it will not try
  -- to re-attach until buffer is properly disabled
  local on_not_in_git = function()
    if H.is_buf_enabled(buf_id) then MiniJJ.disable(buf_id) end
    H.cache[buf_id] = {}
  end

  local on_done = vim.schedule_wrap(function(code, out, err)
    -- Watch git directory only if there was no error retrieving path to it
    if code ~= 0 then return on_not_in_git() end
    H.cli_err_notify(code, out, err)

    -- Update buf data
    local root = out
    if root == nil then return H.notify('No initial data for buffer ' .. buf_id, 'WARN') end
    local repo = root .. '/.jj'
    H.update_buf_data(buf_id, { repo = repo, root = root })

    -- Set up repo watching to react to Git index changes
    H.setup_repo_watch(buf_id, repo)

    -- Set up worktree watching to react to file changes
    -- H.setup_path_watch(buf_id)

    -- Immediately update buffer tracking data
    H.update_git_head(root, { buf_id })
    -- H.update_git_status(root, { buf_id })
  end)

  H.cli_run(command, vim.fn.fnamemodify(path, ':h'), on_done)
end

H.setup_repo_watch = function(buf_id, repo)
  local repo_cache = H.repos[repo] or {}

  -- Ensure repo is watched
  local is_set_up = repo_cache.fs_event ~= nil and repo_cache.fs_event:is_active()
  if not is_set_up then
    H.teardown_repo_watch(repo)
    local fs_event, timer = vim.loop.new_fs_event(), vim.loop.new_timer()

    local on_change = vim.schedule_wrap(function() H.on_repo_change(repo) end)
    local watch = function(_, filename, _)
      -- Ignore temporary changes
      if vim.endswith(filename or '', 'lock') then return end

      -- Debounce to not overload during incremental staging (like in script)
      timer:stop()
      timer:start(50, 0, on_change)
    end
    -- Watch only '.git' dir (non-recursively), as this seems to be both enough
    -- and not supported by libuv (`recursive` flag does nothing,
    -- see https://github.com/libuv/libuv/issues/1778)
    fs_event:start(repo, {}, watch)

    repo_cache.fs_event, repo_cache.timer = fs_event, timer
    H.repos[repo] = repo_cache
  end

  -- Register buffer to be updated on repo change
  local repo_buffers = repo_cache.buffers or {}
  repo_buffers[buf_id] = true
  repo_cache.buffers = repo_buffers
end

H.teardown_repo_watch = function(repo)
  if H.repos[repo] == nil then return end
  pcall(vim.loop.fs_event_stop, H.repos[repo].fs_event)
  pcall(vim.loop.timer_stop, H.repos[repo].timer)
end

-- H.setup_path_watch = function(buf_id, repo)
--   if not H.is_buf_enabled(buf_id) then return end
--
--   -- local on_file_change = function(data) H.update_git_status(H.cache[buf_id].root, { buf_id }) end
--   -- local opts =
--   -- { desc = 'Update Git status', group = H.cache[buf_id].augroup, buffer = buf_id, callback = on_file_change }
--   -- vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost' }, opts)
-- end

H.on_repo_change = function(repo)
  if H.repos[repo] == nil then return end

  -- Collect repo's worktrees with their buffers while doing cleanup
  local repo_bufs, root_bufs = H.repos[repo].buffers, {}
  for buf_id, _ in pairs(repo_bufs) do
    if H.is_buf_enabled(buf_id) then
      local root = H.cache[buf_id].root
      local bufs = root_bufs[root] or {}
      table.insert(bufs, buf_id)
      root_bufs[root] = bufs
    else
      repo_bufs[buf_id] = nil
      MiniJJ.disable(buf_id)
    end
  end

  -- Update Git data
  for root, bufs in pairs(root_bufs) do
    H.update_git_head(root, bufs)
    -- Status could have also changed as it depends on the index
    -- H.update_git_status(root, bufs)
  end
end

H.update_git_head = function(root, bufs)
  local command = H.jj_cmd({
    'log', '-r', '@', '--no-graph', '--ignore-working-copy',
    '--limit', '1', '--template',
    "pad_end(9,change_id.shortest(8))++change_id.shortest(8).rest()"
  })

  local on_done = vim.schedule_wrap(function(code, out, err)
    -- Ensure proper data
    if code ~= 0 then return end
    H.cli_err_notify(code, out, err)

    if out == '' then
      return H.notify('Could not parse HEAD data for root ' .. root .. '\n' .. out, 'WARN')
    end

    local words = {}
    for word in string.gmatch(out, "%S+") do
      table.insert(words, word)
    end

    local rest = words[2]
    local unique_prefix = words[1]:sub(1, 8 - #rest)
    -- local rest_truncated = rest:sub(1, 4 - #unique_prefix)

    -- Update data for all buffers from target `root`
    local new_data = { head = unique_prefix, head_name = rest }
    for _, buf_id in ipairs(bufs) do
      H.update_buf_data(buf_id, new_data)
    end

    -- Redraw statusline to have possible statusline component up to date
    H.redrawstatus()
  end)

  H.cli_run(command, root, on_done)
end

-- H.update_git_status = function(root, bufs)
--   --stylua: ignore
--   local command = H.jj_cmd({
--     -- NOTE: Use `--no-optional-locks` to reduce conflicts with other Git tasks
--     '--no-optional-locks', 'status',
--     '--verbose', '--untracked-files=all', '--ignored', '--porcelain', '-z',
--     '--',
--   })
--   local root_len, path_data = string.len(root), {}
--   for _, buf_id in ipairs(bufs) do
--     -- Use paths relative to the root as in `git status --porcelain` output
--     local rel_path = H.get_buf_realpath(buf_id):sub(root_len + 2)
--     table.insert(command, rel_path)
--     -- Completely not modified paths should be the only ones missing in the
--     -- output. Use this status as default.
--     path_data[rel_path] = { status = '  ', buf_id = buf_id }
--   end
--
--   local on_done = vim.schedule_wrap(function(code, out, err)
--     if code ~= 0 then return end
--     H.cli_err_notify(code, out, err)
--
--     -- Parse CLI output, which is separated by `\0` to not escape "bad" paths
--     for _, l in ipairs(vim.split(out, '\0')) do
--       local status, rel_path = string.match(l, '^(..) (.*)$')
--       if path_data[rel_path] ~= nil then path_data[rel_path].status = status end
--     end
--
--     -- Update data for all buffers
--     for _, data in pairs(path_data) do
--       local new_data = { status = data.status }
--       H.update_buf_data(data.buf_id, new_data)
--     end
--
--     -- Redraw statusline to have possible statusline component up to date
--     H.redrawstatus()
--   end)
--
--   H.cli_run(command, root, on_done)
-- end

H.update_buf_data = function(buf_id, new_data)
  if not H.is_buf_enabled(buf_id) then return end

  local summary = vim.b[buf_id].minijj_summary or {}
  for key, val in pairs(new_data) do
    H.cache[buf_id][key], summary[key] = val, val
  end
  vim.b[buf_id].minijj_summary = summary

  -- Format summary string
  local head = summary.head_name or ''
  -- head = head == 'HEAD' and summary.head:sub(1, 7) or head

  local summary_string = head
  -- local status = summary.status or ''
  -- if status ~= '  ' and status ~= '' then summary_string = string.format('%s (%s)', head, status) end
  vim.b[buf_id].minijj_summary_string = summary_string

  -- Trigger dedicated event with target current buffer (for proper `data.buf`)
  vim.api.nvim_buf_call(buf_id, function() H.trigger_event('MiniJJUpdated') end)
end

-- CLI ------------------------------------------------------------------------
H.jj_cmd = function(args)
  -- Use '-c gc.auto=0' to disable `stderr` "Auto packing..." messages
  -- return { MiniJJ.config.job.jj_executable, '-c', 'gc.auto=0', unpack(args) }
  return { MiniJJ.config.job.jj_executable, unpack(args) }
end

H.cli_run = function(command, cwd, on_done, opts)
  local spawn_opts = opts or {}
  local executable, args = command[1], vim.list_slice(command, 2, #command)
  local process, stdout, stderr = nil, vim.loop.new_pipe(), vim.loop.new_pipe()
  spawn_opts.args, spawn_opts.cwd, spawn_opts.stdio = args, cwd or vim.fn.getcwd(), { nil, stdout, stderr }

  -- Allow `on_done = nil` to mean synchronous execution
  local is_sync, res = false, nil
  if on_done == nil then
    is_sync = true
    on_done = function(code, out, err) res = { code = code, out = out, err = err } end
  end

  local out, err, is_done = {}, {}, false
  local on_exit = function(code)
    -- Ensure calling this only once
    if is_done then return end
    is_done = true

    if process:is_closing() then return end
    process:close()

    -- Convert to strings appropriate for notifications
    out = H.cli_stream_tostring(out)
    err = H.cli_stream_tostring(err):gsub('\r+', '\n'):gsub('\n%s+\n', '\n\n')
    on_done(code, out, err)
  end

  process = vim.loop.spawn(executable, spawn_opts, on_exit)
  H.cli_read_stream(stdout, out)
  H.cli_read_stream(stderr, err)
  vim.defer_fn(function()
    if H.skip_timeout or not process:is_active() then return end
    H.notify('PROCESS REACHED TIMEOUT', 'WARN')
    on_exit(1)
  end, MiniJJ.config.job.timeout)

  if is_sync then vim.wait(MiniJJ.config.job.timeout + 10, function() return is_done end, 1) end
  return res
end

H.cli_read_stream = function(stream, feed)
  local callback = function(err, data)
    if err then return table.insert(feed, 1, 'ERROR: ' .. err) end
    if data ~= nil then return table.insert(feed, data) end
    stream:close()
  end
  stream:read_start(callback)
end

H.cli_stream_tostring = function(stream) return (table.concat(stream):gsub('\n+$', '')) end

H.cli_err_notify = function(code, out, err)
  local should_stop = code ~= 0
  if should_stop then H.notify(err .. (out == '' and '' or ('\n' .. out)), 'ERROR') end
  if not should_stop and err ~= '' then H.notify(err, 'WARN') end
  return should_stop
end

-- Utilities ------------------------------------------------------------------
H.error = function(msg) error('(mini.jj) ' .. msg, 0) end

H.check_type = function(name, val, ref, allow_nil)
  if type(val) == ref or (ref == 'callable' and vim.is_callable(val)) or (allow_nil and val == nil) then return end
  H.error(string.format('`%s` should be %s, not %s', name, ref, type(val)))
end

H.notify = function(msg, level_name) vim.notify('(mini.jj) ' .. msg, vim.log.levels[level_name]) end

H.trigger_event = function(event_name, data) vim.api.nvim_exec_autocmds('User', { pattern = event_name, data = data }) end

-- Try getting buffer's full real path (after resolving symlinks)
H.get_buf_realpath = function(buf_id) return vim.loop.fs_realpath(vim.api.nvim_buf_get_name(buf_id)) or '' end

H.redrawstatus = function() vim.cmd('redrawstatus') end
if vim.api.nvim__redraw ~= nil then H.redrawstatus = function() vim.api.nvim__redraw({ statusline = true }) end end

return MiniJJ
