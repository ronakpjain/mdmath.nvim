-- Tests for `mdmath.blocks`, which locates equations inside comments.
-- Run with: nvim -l tests/blocks.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local ts = vim.treesitter
local blocks = require'mdmath.blocks'

local failures = 0
local skips = 0

local function find_comments(ft, lines, start_row, end_row)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = ft

    local lang = ts.language.get_lang(ft) or ft
    local ok, parser = pcall(ts.get_parser, bufnr, lang)
    if not ok or not parser then
        vim.api.nvim_buf_delete(bufnr, {force = true})
        return nil
    end

    local found = blocks.find_comments(bufnr, parser, start_row or 0, end_row or #lines) or {}
    vim.api.nvim_buf_delete(bufnr, {force = true})

    local result = {}
    for _, block in ipairs(found) do
        result[#result + 1] = {block.sr, block.sc, block.er, block.ec, block.text}
    end

    return result
end

local function test(name, ft, lines, expected, range)
    local found = find_comments(ft, lines, range and range[1], range and range[2])
    if not found then
        skips = skips + 1
        print('skip ' .. name .. ': parser not available')
        return
    end

    if vim.deep_equal(found, expected) then
        print('ok   ' .. name)
        return
    end

    failures = failures + 1
    print('FAIL ' .. name)
    print('  expected: ' .. vim.inspect(expected))
    print('  found:    ' .. vim.inspect(found))
end

test('python: inline equation', 'python', {
    '# Energy: $E = mc^2$',
}, {
    {0, 10, 0, 20, '$E = mc^2$'},
})

test('python: multiple equations in a single comment', 'python', {
    '# $x$ and $y$',
}, {
    {0, 2, 0, 5, '$x$'},
    {0, 10, 0, 13, '$y$'},
})

test('python: shell variables are not equations', 'python', {
    '# use $HOME and $PATH',
}, {})

test('python: padded equation with math signals', 'python', {
    '# $ E = mc^2 $',
}, {
    {0, 2, 0, 14, '$ E = mc^2 $'},
})

test('python: equations outside comments are ignored', 'python', {
    's = "$x^2$"',
}, {})

test('lua: equation in a block comment', 'lua', {
    '--[[ $$\\int_0^1 x^2 dx$$ ]]',
}, {
    {0, 5, 0, 24, '$$\\int_0^1 x^2 dx$$'},
})

test('c: multiline equation in a block comment', 'c', {
    '/*',
    '$$',
    'x^2',
    '$$',
    '*/',
}, {
    {1, 0, 3, 2, '$$\nx^2\n$$'},
})

test('vim: equation in a comment', 'vim', {
    '" $x^2$',
}, {
    {0, 2, 0, 7, '$x^2$'},
})

test('python: comments outside the parsed range are ignored', 'python', {
    '# $x$',
    'y = 1',
}, {}, {1, 2})

if skips > 0 then
    print(string.format('%d test(s) skipped (missing parsers)', skips))
end

if failures > 0 then
    error(string.format('%d test(s) failed', failures))
end

print('all tests passed')
