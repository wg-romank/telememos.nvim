# Telescope picker for usememos

A custom picker for [usememos](https://usememos.com/).

Features:
- [ ] Create a new memo
- [x] Search using `?filter` [api](https://usememos.com/docs/api/memoservice/ListMemos)
- [x] Update memo contents as if writing to a buffer

Install with `Lazy`:

```lua
  {
    "wg-romank/telememos.nvim",
    dependencies = {
      "nvim-telescope/telescope.nvim",
      "nvim-lua/plenary.nvim",
    },
    config = true
  }
```

Options to override:
- `debounce_ms` - how long to wait for picker input before searching
- `min_characters` - how many characters to wait for before searching
- `default_visibility`, `default_state` - as specified in create [API](https://usememos.com/docs/api/memoservice/CreateMemo)
- `default_layout` - your telescope picker [layout](https://github.com/nvim-telescope/telescope.nvim?tab=readme-ov-file#layout-display) configuration

To actually override options pass them as `config` parameter.

```lua
  config = {
    default_visibility = 'PUBLIC',
    default_state = 'STATE_UNSPECIFIED',
    debounce_ms = 250,
    min_characters = 3,
    default_layout = {
      previewer = true,
      layout_strategy = 'vertial',
      layout_config = {
        width = 0.8,
        preview_cutoff = 0,
        height = 0.8,
        prompt_position = "top",
      },
      sorting_strategy = "ascending",
    }
  }
```

Suggested keymaps:
```lua
vim.keymap.set('n', '<leader>mf', require('telememos').memos_picker, { desc = 'Find memo' })
vim.keymap.set('n', '<leader>ms', function ()
  local bufnr = vim.api.nvim_get_current_buf()
  require('telememos').sync_memo_to_api(bufnr, nil, {})
end, { desc = 'Save current buffer as memo' })
```

Opening memo with `<leader>fm` will create `autocmd` for that buffer so it will be linked to memo on your instance. Saving buffer will trigger command to update `contents` on the instance.
