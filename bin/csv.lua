--
--         FILE:  csv.lua
--       AUTHOR:  LeeoNix (Refactored & Optimized)
--  DESCRIPTION:  parse csv file use state machine (Wrapper for csv.core)
--        NOTES:  ---
--

local table, ipairs, type = table, ipairs, type
local csv_mt = require 'csv.core'
local parse, tostring_core = csv_mt.parse_string, csv_mt.__tostring

-- ==========================================
-- 元表方法扩展 (Method Extensions)
-- ==========================================

--- 往 CSV 实例中插入一行新数据
function csv_mt:insert(t)
    if type(t) == 'table' then
        table.insert(self, t)
    else
        -- [修正 1] 作为库方法，遇到非法入参应直接抛出显式错误，而不是 print
        error(string.format('csv:insert expected table, got %s', type(t)), 2)
    end
end

--- 在控制台格式化打印当前 CSV 对象
function csv_mt:print()
    print(tostring_core(self))
end

--- 将当前 CSV 数据导出并保存至磁盘
---@return boolean success 是否成功
---@return string|nil err 错误原因
function csv_mt:write(name)
    local f, err = io.open(name, 'w')
    if f then
        f:write(tostring_core(self))
        f:close()
        return true
    else
        -- [修正 2] 修复 n 未定义 bug，且规范改为返回 nil, err 供上层处理
        return false, string.format("failed to write csv to '%s': %s", tostring(name), tostring(err))
    end
end

--- 对当前 CSV 数据按列进行自定义排序
function csv_mt:sort(func)
    -- 默认按第一列进行升序排序，增加了 (a[1] or "") 防止空行触发比较报错
    func = func or function (a, b) return (a[1] or "") < (b[1] or "") end
    table.sort(self, func)
end

-- ==========================================
-- 模块导出方法 (Module API)
-- ==========================================

local function new()
    return setmetatable({}, csv_mt)
end

--- 解析包含 CSV 格式内容的字符串
---@param s string 原始 CSV 文本
---@return table|nil csv_obj, string|nil err
local function parse_string(s)
    if not s or s == "" then return new() end
    
    local last_char = s:byte(#s)
    if last_char ~= 10 and last_char ~= 13 then
        s = s .. '\n'
    end
    
    -- C 核心层遇到解析错误会返回 nil, "Parse error"
    return parse(new(), s)
end

--- 读取本地 CSV 文件并完成解析
---@param name string 文件路径
---@return table|nil csv_obj, string|nil err
local function open(name)
    local f, err = io.open(name, "r")
    if not f then
        -- [规范] 不再使用 assert 强行 Crash，优雅返回错误
        return nil, string.format("failed to open file '%s': %s", tostring(name), tostring(err))
    end
    
    local s = f:read('*a')
    f:close()
    
    return parse_string(s)
end

--- [极其重要的性能升级]
--- 找出存在于 csv2 但不存在于 csv1 中的行（以第一列的数据作为主键进行比对）
---@param csv1 table 基准 CSV 对象
---@param csv2 table 对比目标 CSV 对象
---@return table diff_csv 仅包含新增差异记录的新 CSV 对象
local function diff(csv1, csv2)
    local t = new()
    
    -- 1. 构建 Hash 索引表 (O(N) 复杂度)
    local lookup_set = {}
    for _, v1 in ipairs(csv1) do
        local key = v1[1]
        if key ~= nil then
            lookup_set[key] = true
        end
    end
    
    -- 2. 利用 Hash 表进行 O(1) 过滤判断 (总体 O(M) 复杂度)
    for _, v2 in ipairs(csv2) do
        local key = v2[1]
        -- 如果在 key 为空（空行）或者在 csv1 中找不到该 key，则视为新增差异
        if key == nil or not lookup_set[key] then
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