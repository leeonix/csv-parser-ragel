-- 将你刚才放在 lua 目录下的 csv.lua 引入
local csv = require 'csv'

-- 1. 一秒内极速载入你几千行的游戏屏蔽词配置表！
local my_table = csv.open("dirty_words.csv")

print("总行数：", #my_table)

-- 2. 丝滑迭代输出 (利用咱们封装的 lines 迭代器)
for id, word, replace in my_table:lines() do
    if id == "3420" then
        print("找到过滤词：", word)
    end
end

-- 3. 修改并序列化回本地磁盘
my_table:insert({"3421", "新增敏感词", "*"})
my_table:write("dirty_words_new.csv")
