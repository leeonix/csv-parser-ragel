-- vi: syntax=lua ts=4 sw=4 et:
-- =====================================================================================
-- Filename:  lua/csv.lua
-- Description:  Lua Object-Oriented Wrapper for High-Performance C CSV Core
-- =====================================================================================

local table, ipairs, type, tostring = table, ipairs, type, tostring
local unpack = unpack or table.unpack

-- 引入底层的 C 语言动态编译模块 (即由 csv_core.c 编译生成的 csv/core.so 或 dll)
local core = require 'csv.core'

-- 定义面向对象元表
local csv_mt = {}
csv_mt.__index = csv_mt

-- =====================================================================================
-- 内部辅助方法：CSV 字段标准序列化格式化 (处理包含逗号、双引号和换行的特殊字段)
-- =====================================================================================
local function escape_csv_field(val)
    local str = tostring(val or "")
    if str:find('[,%"\r\n]') then
        return '"' .. str:gsub('"', '""') .. '"'
    end
    return str
end

-- =====================================================================================
-- 元表方法与面向对象 API
-- =====================================================================================

--- 触发 tostring(csv_obj) 或 print(csv_obj) 时自动序列化为 CSV 规范文本
function csv_mt:__tostring()
    local lines = {}
    for _, row in ipairs(self) do
        local formatted_row = {}
        for i, val in ipairs(row) do
            formatted_row[i] = escape_csv_field(val)
        end
        table.insert(lines, table.concat(formatted_row, ','))
    end
    return table.concat(lines, '\n') .. '\n'
end

--- 插入新行数据
function csv_mt:insert(t)
    if type(t) == 'table' then
        table.insert(self, t)
    else
        error(string.format("csv:insert expected table, got %s", type(t)), 2)
    end
end

--- 控制台打印当前表格
function csv_mt:print()
    print(tostring(self))
end

--- 写回保存到磁盘文件
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

--- 按列排序 (默认按第一列升序)
function csv_mt:sort(func)
    func = func or function (a, b) return (a[1] or "") < (b[1] or "") end
    table.sort(self, func)
end

--- 极速行迭代器 (无缝解构 unpack 返回)
function csv_mt:lines()
    local i = 0
    return function()
        i = i + 1
        local row = self[i]
        if row then
            return unpack(row)
        end
        return nil
    end
end

-- =====================================================================================
-- 导出模块静态工厂函数
-- =====================================================================================

local function new()
    return setmetatable({}, csv_mt)
end

--- 解析内存字符串
local function parse_string(s)
    if not s or s == "" then return new() end
    -- 直接调用底层 C 语言核心库完成高速解析，然后挂上元表
    local raw_table = core.parse_string(s)
    return setmetatable(raw_table, csv_mt)
end

--- 读取物理文件
local function open(filepath)
    -- 直接让底层 C 模块调用 fopen 和 csv_read_file，省去 Lua 层读取文件的内存拷贝
    local raw_table = core.parse_file(filepath)
    return setmetatable(raw_table, csv_mt)
end

--- [O(N+M) 哈希加速版] 找出 csv2 中在 csv1 (以主键列为基准) 不存在的新增行
local function diff(csv1, csv2)
    local t = new()
    local lookup_set = {}
    for _, v1 in ipairs(csv1) do
        if v1[1] ~= nil then lookup_set[v1[1]] = true end
    end
    for _, v2 in ipairs(csv2) do
        if v2[1] == nil or not lookup_set[v2[1]] then
            table.insert(t, v2)
        end
    end
    return t
end

return {
    new          = new,
    open         = open,
    parse_string = parse_string,
    diff         = diff
}