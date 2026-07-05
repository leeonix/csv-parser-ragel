-- =====================================================================================
-- Filename:  csv_core.lua
-- Description: Pure Lua CSV Parser Core using LPeg (Drop-in replacement for csv.c)
-- =====================================================================================

local lpeg = require("lpeg")
local P, C, Cs, Ct, S = lpeg.P, lpeg.C, lpeg.Cs, lpeg.Ct, lpeg.S

-- 兼容 Lua 5.1 (LuaJIT) 和 5.2+ 的 unpack
local unpack = unpack or table.unpack

-- =====================================================================================
-- 1. LPeg 词法与文法定义 (Grammar Definition)
-- =====================================================================================

-- 基础分隔符
local comma = P(",")
local nl    = P("\r")^-1 * P("\n") + P("\r") -- 兼容 Windows(\r\n), Unix(\n), Mac(\r)
local quote = P('"')

-- 规则 A: 普通字段 (Plain Field)
-- 捕获 0 到多个非逗号、非换行、非引号的字符
local plain_field = C((1 - S(',"\r\n'))^0)

-- 规则 B: 引号包裹字段 (Quoted Field)
-- 当遇到连续两个 "" 时，使用 lpeg.Cs 替换为单个 "
local escaped_quote = P('""') / '"'
local non_quote     = 1 - quote
local qcontent      = Cs((escaped_quote + non_quote)^0)
local quoted_field  = quote * qcontent * quote

-- 字段合并规则：优先尝试匹配引号包裹字段，若失败则回退匹配普通字段
local field = quoted_field + plain_field

-- 记录与文件规则：
-- 记录 (Row): 使用 lpeg.Ct 将一行内以逗号分隔的所有字段收集到一个 table 中
local record = Ct(field * (comma * field)^0)

-- 文件 (CSV): 使用 lpeg.Ct 将所有以换行分隔的记录收集到最终的二维 table 中
-- 行尾可带有可选的换行符 (nl^-1)，消除多余空行报错
local csv_grammar = Ct(record * (nl * record)^0 * nl^-1)


-- =====================================================================================
-- 2. 导出接口 (模拟 csv.c/csv_core.c 的 C API)
-- =====================================================================================

local csv_core = {}
csv_core.__index = csv_core 

--- 对应原 C 接口 csv_parse (parse_string)
--- @param t table 目标 Lua table
--- @param s string 原始 CSV 文本
--- @return table|nil obj, string|nil err
function csv_core.parse_string(t, s)
    if type(t) ~= "table" then
        return nil, "Expected table as first argument"
    end
    
    -- 对应原版 C 引擎中长度为 0 直接退出的逻辑
    if type(s) ~= "string" or s == "" then
        return t
    end

    -- 执行 LPeg 状态机匹配
    local parsed_rows = lpeg.match(csv_grammar, s)
    
    if not parsed_rows then
        -- 对应 C 语言中遇到 S_ERR 返回 nil, "Parse error" 的逻辑
        return nil, "Parse error"
    end

    -- 将 LPeg 生成的新行数据填充到目标 table (t) 中
    for i, row in ipairs(parsed_rows) do
        t[i] = row
    end

    return t
end

--- 对应原 C 接口 csv_tostring (__tostring)
--- 负责将 Lua 2D Table 反序列化为标准的 CSV 字符串
function csv_core.__tostring(t)
    local out = {}
    for i = 1, #t do
        local row = t[i]
        if type(row) == "table" then
            local row_out = {}
            for j = 1, #row do
                local field_str = tostring(row[j] or "")
                
                -- 核心判断：若字段包含逗号、双引号或换行符，必须进行引号转义包裹
                if field_str:find('[,"\r\n]') then
                    -- 内部的 " 替换为 ""，并在最外层加上 ""
                    field_str = '"' .. field_str:gsub('"', '""') .. '"'
                end
                
                row_out[j] = field_str
            end
            -- 用逗号连接列
            out[i] = table.concat(row_out, ",")
        end
    end
    -- 用换行符连接行
    return table.concat(out, "\n")
end

--- 对应原 C 接口 csv_lines (lines / read_line)
--- 提供泛型 for 循环迭代器支持
function csv_core.lines(t)
    local index = 0
    return function()
        index = index + 1
        local row = t[index]
        if row then
            return index, unpack(row)
        end
    end
end

return csv_core