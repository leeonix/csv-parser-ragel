-- =====================================================================================
-- Filename:  csv.lua (Unified Edition)
-- Author:    LeeoNix (Refactored to Pure Lua + LPeg)
-- Description: 工业级高性能 CSV 库 (融合了面向对象接口与底层 LPeg 状态机)
-- =====================================================================================

local lpeg = require("lpeg")

-- 性能优化：将常用全局函数缓存为局部变量 (Localize Globals)
local type, tostring, ipairs = type, tostring, ipairs
local table_insert = table.insert
local table_concat = table.concat
local table_sort   = table.sort
local unpack       = unpack or table.unpack

-- =====================================================================================
-- [ 核心引擎 ] LPeg 词法与文法状态机定义
-- =====================================================================================
local P, C, Cs, Ct, S = lpeg.P, lpeg.C, lpeg.Cs, lpeg.Ct, lpeg.S

local comma = P(",")
-- 兼容 Windows(\r\n), Unix(\n), Mac(\r)
local nl    = P("\r")^-1 * P("\n") + P("\r") 
local quote = P('"')

-- 规则 A: 普通字段 (无逗号、无换行、无引号)
local plain_field = C((1 - S(',"\r\n'))^0)

-- 规则 B: 引号包裹字段 (支持原生清洗 "" 转义)
local escaped_quote = P('""') / '"'
local non_quote     = 1 - quote
local qcontent      = Cs((escaped_quote + non_quote)^0)
local quoted_field  = quote * qcontent * quote

-- 字段与行组装
local field       = quoted_field + plain_field
local record      = Ct(field * (comma * field)^0)

-- 【修复空行 Bug 的核心】：定义 EOF (End of File) 断言
-- -P(1) 意味着：如果后面还有 1 个字符，则匹配失败；即只在文件末尾匹配成功，且不消耗任何字符。
local EOF         = -P(1)

-- 文件文法：
-- 1. 循环匹配 "记录 + 换行符"  -> (record * nl)^0
-- 2. 在末尾可选地匹配一行 "残余记录"，前提是：当前游标不能已经处于 EOF！ -> (record - EOF)^-1
-- 这样，如果文件以 \n 结尾，游标已经走到 EOF，就不会再凭空生成一个 {""} 空行了。
local csv_grammar = Ct( (record * nl)^0 * (record - EOF)^-1 )


-- =====================================================================================
-- [ 面向对象 ] CSV 元表方法 (CSV Object Methods)
-- =====================================================================================
local csv_mt = {}
csv_mt.__index = csv_mt

--- 内部引擎：解析 CSV 字符串并追加到当前对象中
--- 等同于原 C 底层的 csv_parse(L) 
function csv_mt:parse_string(s)
    if type(s) ~= "string" or s == "" then
        return self
    end

    local parsed_rows = lpeg.match(csv_grammar, s)
    if not parsed_rows then
        return nil, "Parse error: Invalid CSV format"
    end

    -- 将 LPeg 生成的新行数据合并到当前对象
    local start_idx = #self
    for i, row in ipairs(parsed_rows) do
        self[start_idx + i] = row
    end

    return self
end

--- 序列化引擎：将二维 Table 转换回 CSV 格式的字符串
function csv_mt:__tostring()
    local out = {}
    for i = 1, #self do
        local row = self[i]
        if type(row) == "table" then
            local row_out = {}
            for j = 1, #row do
                local field_str = tostring(row[j] or "")
                -- 若字段包含逗号、双引号或换行符，必须进行转义保护
                if field_str:find('[,"\r\n]') then
                    field_str = '"' .. field_str:gsub('"', '""') .. '"'
                end
                row_out[j] = field_str
            end
            out[i] = table_concat(row_out, ",")
        end
    end
    return table_concat(out, "\n")
end

--- 迭代器辅助函数
local function read_line(t, index)
    index = index + 1
    local row = t[index]
    if not row then return nil end
    return index, unpack(row)
end

--- 泛型 for 循环迭代器
function csv_mt:lines()
    return read_line, self, 0
end

--- 往 CSV 实例中插入一行新数据
function csv_mt:insert(t)
    if type(t) == 'table' then
        table_insert(self, t)
    else
        error(string.format('csv:insert expected table, got %s', type(t)), 2)
    end
end

--- 排序 (默认以第一列作为升序主键)
function csv_mt:sort(func)
    func = func or function (a, b) return (a[1] or "") < (b[1] or "") end
    table_sort(self, func)
end

--- 将当前 CSV 数据导出至磁盘
function csv_mt:write(name)
    local f, err = io.open(name, 'w')
    if f then
        f:write(tostring(self))
        f:close()
        return true
    else
        return false, string.format("failed to write csv to '%s': %s", tostring(name), tostring(err))
    end
end

--- 控制台格式化打印
function csv_mt:print()
    print(tostring(self))
end


-- =====================================================================================
-- [ 模块接口 ] 对外公开的静态 API (Module Public API)
-- =====================================================================================
local csv = {}

--- 创建一个空的 CSV 实例
function csv.new()
    return setmetatable({}, csv_mt)
end

--- 解析包含 CSV 格式内容的字符串并返回新实例
function csv.parse_string(s)
    local obj = csv.new()
    return obj:parse_string(s)
end

--- 读取本地 CSV 文件并完成解析
function csv.open(name)
    local f, err = io.open(name, "r")
    if not f then
        return nil, string.format("failed to open file '%s': %s", tostring(name), tostring(err))
    end
    
    local s = f:read('*a')
    f:close()
    
    return csv.parse_string(s)
end

--- 集合运算：找出 csv2 中存在但 csv1 中不存在的行 (按首列主键比对)
function csv.diff(csv1, csv2)
    local t = csv.new()
    local lookup_set = {}
    
    -- 构建 Hash 索引 O(N)
    for _, v1 in ipairs(csv1) do
        local key = v1[1]
        if key ~= nil then lookup_set[key] = true end
    end
    
    -- 过滤差异 O(M)
    for _, v2 in ipairs(csv2) do
        local key = v2[1]
        if key == nil or not lookup_set[key] then
            table_insert(t, v2)
        end
    end
    
    return t
end

-- 导出模块
return csv