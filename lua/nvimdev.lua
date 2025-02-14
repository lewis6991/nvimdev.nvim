local async = require('plenary.async.async')
local scheduler = require('plenary.async.util').scheduler

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace('nvim_test')

local function get_test_lnum(lnum, inc_describe)
  lnum =  lnum or vim.fn.line('.')
  local test
  local test_lnum
  for i = lnum, 1, -1 do
    for _, pat in ipairs {
      "^%s*it%s*%(%s*['\"](.*)['\"']%s*,",
      inc_describe and "^%s*describe%s*%(%s*['\"](.*)['\"']%s*,"
    } do
      if pat then
        test = vim.fn.getline(i):match(pat)
        if test then
          test_lnum = i
          break
        end
      end
    end
    if test then
      break
    end
  end

  return test, test_lnum
end

local function get_test_lnums(all)
  local lnum = vim.fn.line(all and '$' or '.')

  local res = {}
  repeat
    local test, test_lnum = get_test_lnum(lnum, false)
    if test then
      res[#res+1] = {test, test_lnum}
      if not all then
        break
      end
      lnum = test_lnum - 1
    end
  until not test

  return res
end

local function filter_test_output(in_lines)
  local lines = {}
  local collect = false
  for _, l in ipairs(in_lines) do
    if not collect and l:match('%[ RUN') then
      collect = true
    end
    if collect and l ~= '' then
      if l:match('Tests exited non%-zero:') then
        break
      end
      lines[#lines+1] = l
    end
  end

  if #lines == 0 then
    lines = in_lines
  end
  return lines
end

local function create_virt_lines(lines)
  local virt_lines = {}
  for _, l in ipairs(lines) do
    virt_lines[#virt_lines+1] = {{l, 'ErrorMsg'}}
  end
  return virt_lines
end

local function apply_pending_decor(bufnr, lnum)
  api.nvim_buf_set_extmark(bufnr, ns, lnum-1, -1, {
    id = lnum,
    virt_text = {{'RUNNING...', 'WarningMsg' }},
    virt_lines_above = true
  })
end

local function apply_result_decor(bufnr, lnum, code, stdout)
  local virt_text, virt_lines

  if code > 0 then
    virt_text = {'FAILED', 'ErrorMsg' }

    local stdout_lines = vim.split(stdout, '\n')
    local lines = filter_test_output(stdout_lines)
    virt_lines = create_virt_lines(lines)
  else
    virt_text = {'PASSED', 'MoreMsg' }
  end

  api.nvim_buf_set_extmark(bufnr, ns, lnum-1, -1, {
    id = lnum,
    virt_text = {virt_text},
    virt_lines = virt_lines,
    virt_lines_above = true
  })
end

local function notify_err(msg)
  vim.notify(msg, vim.log.levels.ERROR)
end

local run_target = async.wrap(function(cwd, path, test, callback)
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)

  local stdout_data = ''

  vim.loop.spawn('make', {
    args = {
      'functionaltest',
      'TEST_FILE='..path,
      'TEST_FILTER='..test
    },
    cwd = cwd,
    stdio = { nil, stdout, stderr },
  },
    function(code)
      if stdout then stdout:read_stop() end
      if stderr then stderr:read_stop() end

      if stdout and not stdout:is_closing() then stdout:close() end
      if stderr and not stderr:is_closing() then stderr:close() end

      callback(code, stdout_data)
    end
  )

  stdout:read_start(function(_, data)
    if data then
      stdout_data = stdout_data..data
    end
  end)

  stderr:read_start(function(_, data)
    if data then
      stdout_data = stdout_data..data
    end
  end)
end, 4)

M.run_test = async.void(function(props)
  local all = props.args == 'all'

  local name = api.nvim_buf_get_name(0)
  if not name:match('^.*/test/functional/.*$') then
    notify_err('Buffer is not an nvim functional test file')
    return
  end

  local targets = get_test_lnums(all)

  if #targets == 0 then
    notify_err('Could not find test')
    return
  end

  local cwd = name:match('^(.*)/test/functional/.*$')
  local cbuf = api.nvim_get_current_buf()

  for i = #targets, 1, -1 do
    local _, test_lnum = unpack(targets[i])
    apply_pending_decor(cbuf, test_lnum)
  end

  for i = #targets, 1, -1 do
    local test, test_lnum = unpack(targets[i])
    local code, stdout = run_target(cwd, name, test)
    scheduler()
    apply_result_decor(cbuf, test_lnum, code, stdout)
  end
end)

function M.clear_test_decor()
  api.nvim_buf_clear_namespace(0, ns, 0, -1)
  vim.cmd'redraw'
end

return M
