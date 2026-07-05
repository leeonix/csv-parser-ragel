-- 引入我们编写的 C 扩展和 Lua 包装层
local csv = require 'csv'

-- 准备一个简单的 CSV 测试字符串
local csv_data = [[
id,name,description
1,LeeoNix,"Hacker ""Programmer"""
2,Ragel,"High-performance ""Finite State Machine"""
3,TotalCommander,"Plugin ""CSV"" Viewer"
]]

print("--- 1. 测试字符串解析 ---")
local tbl = csv.parse_string(csv_data)
print("第一行类型:", type(tbl[1])) -- 这里必须输出 table！如果输出 string，说明 C 层没塞进表。

-- 调试打印：检查返回的结构
for k, v in pairs(tbl) do
    print(string.format("Key: %s, Type: %s, Value: %s", k, type(v), tostring(v)))
end

local tbl = csv.parse_string(csv_data)
tbl:print()

print("\n--- 2. 测试文件读取 (读入屏蔽词表) ---")
-- 假设你目录下有一个 dirty_words.csv
local filename = "dirty_words.csv"
local status, err = pcall(function()
    local words = csv.open(filename)
    print(string.format("成功加载文件: %s, 总行数: %d", filename, #words))
    
    -- 打印前 5 行看看效果
    for i = 1, 5 do
        if words[i] then
            print(string.format("Row %d: %s", i, table.concat(words[i], " | ")))
        end
    end
    
    -- 测试排序功能
    words:sort(function(a, b) return a[1] > b[1] end)
    print("排序完成，第一行 ID: " .. words[1][1])
end)

if not status then
    print("测试文件读取失败: " .. tostring(err))
end

print("\n--- 3. 测试 Diff 功能 (对比) ---")
local csv1 = csv.parse_string("1,a\n2,b")
local csv2 = csv.parse_string("1,a\n2,b\n3,c")
local diff_res = csv.diff(csv1, csv2)

print("差异行内容 (应为 3,c):")
diff_res:print()
