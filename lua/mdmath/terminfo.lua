local api = vim.api

local M = {}

local winsize = nil

-- Wire up the async CSI 16t update callback so that when the terminal
-- responds with real pixel dimensions, the cached size is refreshed.
local _system = require'mdmath.terminfo._system'
_system._on_update = function(new_size)
    winsize = new_size
end

function M.size()
    if winsize == nil then
        local s, err = _system.request_size()
        if not s then
            error('Failed to get terminal size: code ' .. tostring(err))
        end
        winsize = s
    end

    return winsize
end

function M.cell_size()
    local size = M.size()

    local width = size.xpixel / size.col
    local height = size.ypixel / size.row

    return width, height
end

function M.refresh()
    winsize = nil
end

local function create_autocmd()
    api.nvim_create_autocmd('VimResized', {
        callback = function()
            M.refresh()
        end
    })
end

if vim.in_fast_event() then
    vim.schedule(create_autocmd)
else
    create_autocmd()
end

return M
