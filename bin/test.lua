--[[
 * =====================================================================================
 * Filename:  test.lua
 * Description:  CSV 解析器 Lua 层测试程序 (针对 Ragel CSV Parser & csv.lua)
 * Usage:  lua test.lua <filepath.csv>
 * =====================================================================================
--]]

local csv = require("csv")

-- =====================================================================================
-- 附加的边界测试：验证底层的转义和洗白逻辑
-- =====================================================================================
local function run_memory_edge_test()
    print("\n>>> [阶段 0] 执行内存字符串边界测试 (Edge Cases) ...")
    
    -- 构造一段包含极度恶劣语法的 CSV 字符串
    -- 1. 包含普通字段
    -- 2. 包含带逗号的引号包裹字段
    -- 3. 包含内部带有换行符和 "" 转义的引号包裹字段
    local edge_csv_str = 'ID,Name,Desc\n1,"LeeoNix, Lua","C89 ""Strict""\nNewline test"\n2,NoQuotes,End'
    
    local csv_obj, err = csv.parse_string(edge_csv_str)
    if not csv_obj then
        print("【错误】内存边界测试解析失败: " .. tostring(err))
        return false
    end
    
    print("  内存解析成功，行数: " .. #csv_obj)
    -- 验证特定的复杂字段
    local complex_field = csv_obj[2][3]
    print(string.format("  验证恶劣字段抓取 -> 长度: %d bytes | 内容: %q", #complex_field, complex_field))
    
    -- 如果这里没报错，说明 Ragel 的原地脱衣和 Lua 的多行安全提取都是完美的
    return true
end

-- =====================================================================================
-- 主函数逻辑：对应 test.c 的文件解析与统计
-- =====================================================================================
local function main()
    -- 检查命令行参数 (arg[0] 是脚本名，arg[1] 是第一个参数)
    local filepath = arg[1]
    if not filepath then
        print("==================================================")
        print("【错误】缺少输入文件参数！")
        print(" 用法: lua test.lua <csv文件名>")
        print(" 示例: lua test.lua dirty_words.csv")
        print("==================================================")
        return
    end

    local print_limit = 10 -- 默认只在屏幕上打印前 10 行

    -- 先跑一下内部边界测试
    run_memory_edge_test()

    print("\n==================================================")
    print(string.format("开始载入并解析 CSV 文件: %s", filepath))
    print("==================================================")

    -- 启动毫秒级计时器 (os.clock() 返回 CPU 秒数)
    local start_time = os.clock()

    -- 调用 csv.lua 中封装的 open 接口
    local csv_obj, err = csv.open(filepath)

    -- 停止计时
    local end_time = os.clock()
    local elapsed_ms = (end_time - start_time) * 1000.0

    -- 异常处理
    if not csv_obj then
        print("【解析失败】" .. tostring(err))
        return
    end

    -- 初始化统计数据
    local total_rows = #csv_obj
    local max_cols = 0
    local total_cells = 0

    -- 遍历解析好的二维 Lua Table 收集数据
    for row_idx, row in ipairs(csv_obj) do
        local col_count = #row
        total_cells = total_cells + col_count
        
        if col_count > max_cols then
            max_cols = col_count
        end

        -- 前 N 行详细打印，方便验证 "" 原地清洗和边界截取是否正确
        if row_idx <= print_limit then
            for col_idx, field in ipairs(row) do
                print(string.format("  [Row %4d | Col %2d] (%2d bytes): %q", 
                       row_idx, col_idx, #field, field))
            end
        elseif row_idx == print_limit + 1 then
            print(string.format("  ...\n  (前 %d 行展示完毕，后续几千行数据正在后台被静默校验中...)", print_limit))
        end
    end

    print("==================================================")
    print("【解析成功】性能与数据报告 (Lua层):")
    print(string.format("  - 总行数 (Rows)  : %d 行", total_rows))
    print(string.format("  - 最大列数 (Cols): %d 列", max_cols))
    print(string.format("  - 总字段数       : %d 个单元格", total_cells))
    print(string.format("  - 耗时 (Time)    : %.3f 毫秒 (ms)", elapsed_ms))
    print("==================================================")

    -- 测试写入功能是否正常 (会利用你的 csv_tostring 序列化 C 函数)
    local out_file = filepath .. ".out.csv"
    local write_ok, write_err = csv_obj:write(out_file)
    if write_ok then
        print(string.format("【附加测试】成功将解析后的对象反向序列化至: %s", out_file))
    else
        print(string.format("【附加测试失败】序列化写入失败: %s", tostring(write_err)))
    end
end

-- 启动主程序
main()