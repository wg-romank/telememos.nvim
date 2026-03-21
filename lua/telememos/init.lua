local M = {}

M.MEMOS_URL = vim.env.MEMOS_URL
M.API_TOKEN = vim.env.MEMOS_TOKEN

M.last_results = {}
M.last_processed_prompt = ""
M.debounce_timer = vim.loop.new_timer()

local default_opts = {
  name_prefix = '[M]',
  max_header_length = 20,
  default_visibility = 'PUBLIC',
  default_state = 'STATE_UNSPECIFIED',
  debounce_ms = 250,
  min_characters = 3,
  default_layout = {
    previewer = true,
    layout_strategy = 'vertical',
    layout_config = {
      width = 0.8,
      preview_cutoff = 0,
      height = 0.8,
      prompt_position = "top",
    },
    sorting_strategy = "ascending",
  }
}

M.setup = function(opts)
  local opts = vim.tbl_deep_extend("force", default_opts, opts)
  M.config = opts or {}
end

local function fetch_memos(search)
  local curl = require('plenary.curl')
  local url = M.MEMOS_URL .. '/api/v1/memos'
  local all_memos = {}
  -- local next_page_token = ''
  -- repeat
  local res = curl.get(url, {
    headers = {
      Authorization = "Bearer " .. M.API_TOKEN,
      ["Content-Type"] = "application/json",
    },
    query = {
      pageSize = 20,
      filter = "content.contains('" .. search .. "')"
    }
  })

  if res.status ~= 200 then
    vim.notify("API Error: " .. res.status, vim.log.levels.ERROR)
    return nil
  end

  -- TODO
  local ok, decoded = pcall(vim.fn.json_decode, res.body)
  if decoded.memos then
    for _, memo in ipairs(decoded.memos) do
      table.insert(all_memos, memo)
    end
  end
  --   next_page_token = decoded.nextPageToken or ""
  -- until next_page_token == ''
  return all_memos
end

local function fetch_memo_by_id(bufnr, memo_id)
  local curl = require('plenary.curl')
  local api_url = M.MEMOS_URL .. '/api/v1/memos'

  -- If we have an ID, we target the specific resource and use PATCH
  local pattern = "/" .. "(.*)"
  local head = string.match(memo_id, pattern)
  local url = memo_id and (api_url .. "/" .. head) or api_url

  curl.get(url, {
    headers = {
      authorization = "Bearer " .. M.API_TOKEN,
      content_type = "application/json",
    },
    callback = function(res)
      vim.schedule(function()
        if res.status >= 200 and res.status < 300 then
          -- TODO
          local ok, entry = pcall(vim.fn.json_decode, res.body)
          local lines = vim.split(entry.content, "\n")
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
          vim.api.nvim_buf_set_option(bufnr, 'modified', false)
        else
          vim.notify("Error: " .. res.status .. " - " .. res.body)
        end
      end)
    end,
  })
end

local function memos_entry_maker(data)
  local content = data.content or ""
  local heading = content:match("^#+%s*(.-)\n")

  local display = nil
  if heading then
    display = heading
  else
    display = data.content
    if #display > 120 then
      display = display:sub(1, 117) .. "..."
    end
  end

  return {
    value = data,
    memo_id = data.name,
    display = display,
    heading = heading,
    ordinal = heading or content,
    content = content,
  }
end

local function setup_memo_buffer(bufnr, entry)
  local title = entry.display:sub(1, M.config.max_header_length)
  vim.api.nvim_buf_set_name(bufnr, M.config.name_prefix .. (entry.heading or title))
  vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown") -- TODO: buftype
  -- vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe") -- delete on close
  vim.b[bufnr].memo_id = entry.memo_id -- linking memo using its name

  vim.b[bufnr].autocmd_id = vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      M.save_memo(bufnr, entry.value)
    end,
  })
end

M.save_memo = function(bufnr, memo)
  local curl = require('plenary.curl')
  local api_url = M.MEMOS_URL .. '/api/v1/memos'
  local token = M.API_TOKEN

  local visibility = memo and memo.visibility or 'PUBLIC'
  local state = memo and memo.state or 'STATE_UNSPECIFIED'

  local bufnr = bufnr or vim.api.nvim_get_current_buf()
  local memo_id = vim.b[bufnr].memo_id

  -- If we have an ID, we target the specific resource and use PATCH
  local pattern = "/" .. "(.*)"
  local head = nil
  if memo_id then
    head = string.match(memo_id, pattern)
  end
  local url = memo_id and (api_url .. "/" .. head) or api_url
  local method = memo_id and "patch" or "post"

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Perform the async request
  curl[method](url, {
    body = vim.fn.json_encode({ content = content, visibility = visibility, state = state }),
    headers = {
      authorization = "Bearer " .. token,
      content_type = "application/json",
    },
    callback = function(res)
      vim.schedule(function()
        if res.status >= 200 and res.status < 300 then
          if not memo_id then
            local ok, decoded = pcall(vim.fn.json_decode, res.body)
            if decoded.name then
              local entry = memos_entry_maker({ name = decoded.name, content = content })
              setup_memo_buffer(bufnr, entry)
              vim.notify("Memo synced (" .. decoded.name .. ")") -- TODO: use link to memo
            end
          else
            vim.notify("Memo synced (" .. res.status .. ")")
          end
          vim.api.nvim_buf_set_option(bufnr, 'modified', false)
        else
          vim.notify("Error: " .. res.status .. " - " .. res.body)
        end
      end)
    end,
  })
end

M.memos_picker = function()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new(M.config.default_layout, {
    prompt_title = "Memos",
    finder = finders.new_dynamic({
      fn = function(prompt)
        M.debounce_timer:stop()
        if not prompt or #prompt < M.config.min_characters then
          M.results_cache = {}
          M.last_processed_prompt = ""
          return M.last_results
        end

        if M.last_processed_prompt == prompt then
          return M.last_results
        end

        M.debounce_timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(function()
          local prompt_bufnr = vim.api.nvim_get_current_buf()
          local current_picker = action_state.get_current_picker(prompt_bufnr)

          if current_picker then
            M.last_results = fetch_memos(prompt)
            M.last_processed_prompt = prompt
            current_picker:refresh()
          end
        end))

        return M.last_results
      end,
      entry_maker = memos_entry_maker
    }),
    sorter = require("telescope.sorters").get_fzy_sorter(), --opts here?
    previewer = previewers.new_buffer_previewer({
      title = "Memo Preview",
      define_preview = function(self, entry)
        local lines = vim.split(entry.content, "\n")
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_option(self.state.bufnr, "filetype", "markdown")

        local winid = self.state.winid
        vim.api.nvim_win_set_option(winid, "wrap", true)      -- Enable visual wrapping
        vim.api.nvim_win_set_option(winid, "linebreak", true) -- Wrap at word boundaries
        vim.api.nvim_win_set_option(winid, "list", false)     -- Required for linebreak to work
        vim.api.nvim_win_set_option(winid, "number", false)
        vim.api.nvim_win_set_option(winid, "relativenumber", false)
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)

        local selection = action_state.get_selected_entry()

        local bufnr = vim.api.nvim_create_buf(true, false) -- listed, scratch
        vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'hide')

        fetch_memo_by_id(bufnr, selection.memo_id)

        setup_memo_buffer(bufnr, selection)

        vim.api.nvim_set_current_buf(bufnr)
      end)
      return true
    end,
  }):find()
end

M.delete_memo = function(bufnr)
  local bufnr = bufnr or vim.api.nvim_get_current_buf()
  
  local memo_id = vim.b[bufnr].memo_id
  local pattern = "/" .. "(.*)"
  local head = string.match(memo_id, pattern)
  local api_url = M.MEMOS_URL .. '/api/v1/memos'
  local url = api_url .. "/" .. head
  local curl = require('plenary.curl')

  curl.delete(url, {
    headers = {
      authorization = "Bearer " .. M.API_TOKEN,
      content_type = "application/json",
    },
    callback = function(res)
      vim.schedule(function()
        if res.status >= 200 and res.status < 300 then
          -- TODO
          local id_to_remove = vim.b[bufnr].autocmd_id
          if id_to_remove then
            vim.api.nvim_del_autocmd(id_to_remove)
            vim.b[bufnr].autocmd_id = nil
          end
          M.last_results = {} -- TODO: better way of doing this by removing a single entry
          vim.notify("Deleted")
        else
          vim.notify("Error: " .. res.status .. " - " .. res.body)
        end
      end)
    end,
  })
end

return M
