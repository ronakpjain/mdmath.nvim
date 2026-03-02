local ffi = require'ffi'

local M = {}

local TIOCGWINSZ

-- Based on hologram.nvim
if vim.fn.has('linux') == 1 then
    TIOCGWINSZ = 0x5413
elseif vim.fn.has('mac') == 1 then
    TIOCGWINSZ = 0x40087468
elseif vim.fn.has('bsd') == 1 then
    TIOCGWINSZ = 0x40087468
else
    error('mdmath.nvim: Unsupported platform, please report this issue')
end

ffi.cdef[[
struct mdmath_winsize
{
    unsigned short int ws_row;
    unsigned short int ws_col;
    unsigned short int ws_xpixel;
    unsigned short int ws_ypixel;
};

int ioctl(int fd, unsigned long op, ...);
int open(const char *path, int oflag, ...);
int close(int fd);
]]

local O_RDONLY = 0
local O_NOCTTY = 0x20000

-- Try TIOCGWINSZ on a file descriptor.
-- Returns a size table only if the ioctl succeeds AND pixel fields are non-zero.
local function try_ioctl_full(fd)
    local ws = ffi.new 'struct mdmath_winsize'
    if ffi.C.ioctl(fd, TIOCGWINSZ, ws) >= 0 and ws.ws_xpixel > 0 and ws.ws_ypixel > 0 then
        return {
            row    = ws.ws_row,
            col    = ws.ws_col,
            xpixel = ws.ws_xpixel,
            ypixel = ws.ws_ypixel,
        }
    end
    return nil
end

-- Query row/col counts via TIOCGWINSZ (pixel fields are not required).
local function get_rowcol()
    local ws = ffi.new 'struct mdmath_winsize'
    for _, fd in ipairs({ 1, 0, 2 }) do
        if ffi.C.ioctl(fd, TIOCGWINSZ, ws) >= 0 and ws.ws_row > 0 then
            return ws.ws_row, ws.ws_col
        end
    end
    -- Fall back to nvim's own knowledge of the terminal dimensions.
    return vim.o.lines, vim.o.columns
end

-- Default cell pixel dimensions used as a fallback when the terminal does not
-- report pixel info via TIOCGWINSZ (e.g. kitty intentionally leaves those
-- fields as zero).  These are typical values for a 1080p display; they will
-- be overridden by the async CSI 16t query below.
local DEFAULT_CELL_W = 9
local DEFAULT_CELL_H = 18

-- Callback registered by terminfo.lua so we can push an updated size after
-- the async CSI 16t response arrives.
M._on_update = nil

-- Send the CSI 16t escape sequence and capture the response via nvim's
-- TermResponse autocmd.  When successful, calls M._on_update(size).
-- This must run in a non-fast event context (use vim.schedule if needed).
local function query_cell_size_async()
    -- Only worth doing when nvim has a real UI attached (interactive session).
    local uis = vim.api.nvim_list_uis()
    if #uis == 0 then
        return
    end

    local augroup = vim.api.nvim_create_augroup('mdmath_termsize', { clear = true })
    local timer = vim.uv.new_timer()

    local function cleanup(id)
        if timer and not timer:is_closing() then
            timer:stop()
            timer:close()
        end
        pcall(vim.api.nvim_del_autocmd, id)
    end

    local autocmd_id
    autocmd_id = vim.api.nvim_create_autocmd('TermResponse', {
        group = augroup,
        callback = function(ev)
            local seq = ev.data and ev.data.sequence or ''
            -- CSI 16t response: ESC [ 6 ; <height_px> ; <width_px> t
            local h, w = seq:match('\x1b%[6;(%d+);(%d+)t')
            if not h then
                -- Try without the leading ESC (some nvim versions strip it)
                h, w = seq:match('%[6;(%d+);(%d+)t')
            end
            h, w = tonumber(h), tonumber(w)
            if not h or not w or h == 0 or w == 0 then
                return  -- not our response, keep listening
            end

            cleanup(autocmd_id)

            if M._on_update then
                local rows, cols = get_rowcol()
                M._on_update({
                    row    = rows,
                    col    = cols,
                    xpixel = cols * w,
                    ypixel = rows * h,
                })
            end
            return true  -- delete this autocmd
        end,
    })

    -- Time-out after 1 second; don't keep listening forever.
    timer:start(1000, 0, vim.schedule_wrap(function()
        cleanup(autocmd_id)
    end))

    -- Send the query.  io.stdout:write bypasses nvim's rendering pipeline
    -- and writes directly to the terminal fd.
    io.stdout:write('\x1b[16t')
    io.stdout:flush()
end

function M.request_size()
    -- 1. Try standard fds — works in most terminals where xpixel/ypixel are set.
    for _, fd in ipairs({ 1, 0, 2 }) do
        local s = try_ioctl_full(fd)
        if s then return s end
    end

    -- 2. Try /dev/tty directly — works when nvim is launched without a
    --    controlling TTY on any of the standard fds.
    local tty_fd = ffi.C.open('/dev/tty', O_RDONLY + O_NOCTTY)
    if tty_fd >= 0 then
        local s = try_ioctl_full(tty_fd)
        ffi.C.close(tty_fd)
        if s then return s end
    end

    -- 3. The terminal (e.g. kitty) does not populate the pixel fields of
    --    TIOCGWINSZ.  Return a provisional size based on reasonable defaults
    --    and kick off an async CSI 16t query that will update the cache once
    --    the terminal responds.
    local rows, cols = get_rowcol()

    -- Schedule the async query (must not run in a fast-event context).
    if not vim.in_fast_event() then
        query_cell_size_async()
    else
        vim.schedule(query_cell_size_async)
    end

    return {
        row    = rows,
        col    = cols,
        xpixel = cols * DEFAULT_CELL_W,
        ypixel = rows * DEFAULT_CELL_H,
    }
end

return M
