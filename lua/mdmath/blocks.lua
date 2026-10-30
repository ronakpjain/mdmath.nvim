local ts = vim.treesitter

local M = {}

local latex_query = nil

local function get_latex_query()
    if not latex_query then
        latex_query = ts.query.parse('markdown_inline', '(latex_block) @block')
    end

    return latex_query
end

-- Most grammars name comments `comment`, but some (like `latex`) use
-- `line_comment`/`block_comment`. Descendants are not visited once a node
-- matches, so types like Lua's `comment_content` are not reported twice.
local function is_comment(node)
    return node:type():find('comment', 1, true) ~= nil
end

-- `markdown_inline` matches any pair of `$`, which is very common inside
-- comments (`$HOME`, `$1`, ...). Single-dollar equations are therefore only
-- accepted when the delimiters are not directly followed/preceded by
-- whitespace, unless the equation contains other clear math signals.
local function looks_like_math(text)
    if text:sub(1, 2) == '$$' then
        return true
    end

    local equation = text:sub(2, -2)
    if equation == '' then
        return false
    end

    if not equation:match('^%s') and not equation:match('%s$') then
        return true
    end

    return equation:match('\\%a') ~= nil or equation:match('[%^_%{%}]') ~= nil
end

-- Finds every equation in the buffer using the markdown parser and its
-- injected `markdown_inline` trees. Returns a list of blocks with absolute
-- (0-indexed) positions, or nil when the buffer cannot be parsed.
function M.find_markdown(bufnr, parser, start_row, end_row)
    parser:parse({start_row, end_row})

    local inlines = parser:children()['markdown_inline']
    if not inlines then
        return nil
    end

    local query = get_latex_query()
    local blocks = {}

    local function collect(tree)
        for _, node in query:iter_captures(tree:root(), bufnr, start_row, end_row) do
            local sr, sc, er, ec = node:range()
            blocks[#blocks + 1] = {
                text = ts.get_node_text(node, bufnr),
                sr = sr,
                sc = sc,
                er = er,
                ec = ec,
            }
        end
    end

    inlines:for_each_tree(collect)

    return blocks
end

-- Finds every equation inside comments of the buffer's own language, e.g.
-- `# $x^2$` in Python or `--[[ $$x$$ ]]` in Lua. Each comment is parsed
-- separately as a `markdown_inline` document, which gives equations relative
-- to the comment text, so their positions are converted back to buffer
-- coordinates before returning. Returns a list of blocks, or nil when the
-- buffer cannot be parsed.
function M.find_comments(bufnr, parser, start_row, end_row)
    local trees = parser:parse({start_row, end_row})
    local root = trees and trees[1] and trees[1]:root()
    if not root then
        return nil
    end

    local query = get_latex_query()
    local blocks = {}

    local function collect(node)
        local sr, _, er = node:range()
        if er < start_row or sr >= end_row then
            return
        end

        if is_comment(node) then
            local nsr, nsc = node:range()
            local text = ts.get_node_text(node, bufnr)

            -- Avoid creating a parser for comments without a single `$`.
            if text:find('$', 1, true) then
                local string_parser = ts.get_string_parser(text, 'markdown_inline')

                for _, node_block in query:iter_captures(string_parser:parse()[1]:root(), text) do
                    local equation = ts.get_node_text(node_block, text)
                    if looks_like_math(equation) then
                        local bs, bc, be, bec = node_block:range()

                        blocks[#blocks + 1] = {
                            text = equation,
                            sr = nsr + bs,
                            -- Only the first line of a comment is offset by
                            -- the column where the comment itself starts.
                            sc = bs == 0 and nsc + bc or bc,
                            er = nsr + be,
                            ec = be == 0 and nsc + bec or bec,
                        }
                    end
                end
            end

            return
        end

        for child in node:iter_children() do
            collect(child)
        end
    end

    collect(root)

    return blocks
end

return M
