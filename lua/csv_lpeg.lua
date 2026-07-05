-- =====================================================================================
-- Filename:    csv.lua
-- Description: 工业级全功能 LPeg CSV 解析与面向对象操作库 (终极无懈可击版)
-- Architecture: 基于 Parsing Expression Grammars (LPeg) 的纯 Lua 极速解析引擎
--
-- 核心工业级特性：
-- 1. 极致性能优化：将常用全局函数全面局部变量化 (Localize Globals)，消除虚拟机高频查找开销。
-- 2. 强力防静默截断：在 LPeg 主文法尾部引入严格的 EOF (* -1) 锚定，杜绝语法畸变时静默产出残缺数据。
-- 3. 幽灵空行斩断：采用负向前瞻断言 -(nl + -1) 与空行海绵 nl^1，从文法底层斩断 {""} 幽灵行。
-- 4. 防死循环编译保护：标准行强制绑定 nl^1，静态保证 ^0 循环至少消耗 1 字符，彻底杜绝 LPeg 编译报错。
-- 5. 全面换行兼容：完美兼容 Windows (\r\n)、Linux/macOS (\n) 以及老式 Mac (\r) 格式。
-- 6. 无状态迭代器：重构 lines() 为零内存分配 (Zero-Allocation) 迭代器，消除高频遍历时的 GC 压力。
-- 7. 二进制安全 I/O：文件读写强制采用 "rb" 和 "wb" 模式，规避操作系统对换行符的隐式篡改。
-- 8. 流式分片追加：核心解析引擎支持对现有实例多次追加解析内容，增强了网络流与分片处理能力。
-- =====================================================================================

local lpeg = require("lpeg")

-- =====================================================================================
-- [性能优化] 将常用全局函数与标准库函数缓存为局部变量 (Localize Globals)
-- 虚拟机在高频循环访问局部变量时直接读取寄存器 (GETLOCAL)，速度远快于查询全局哈希表
-- =====================================================================================
local type, tostring, ipairs, error = type, tostring, ipairs, error
local table_insert  = table.insert
local table_concat  = table.concat
local table_sort    = table.sort
local string_format = string.format
local io_open       = io.open
local unpack        = unpack or table.unpack -- 完美兼容 Lua 5.1 至 Lua 5.4+

-- =====================================================================================
-- 第一部分：底层 LPeg 核心状态机文法定义 (零宽防漏、安全锁定)
-- =====================================================================================
local P, C, Cs, Ct, S = lpeg.P, lpeg.C, lpeg.Cs, lpeg.Ct, lpeg.S

local comma = P(",")

-- 跨平台换行符兼容规则：优先匹配 \r\n，其次匹配 \n，最后兼容旧式 Mac 的 \r
local nl    = P("\r")^-1 * P("\n") + P("\r") 
local quote = P('"')

-- 规则 A: 普通无引号字段 (匹配并捕获不包含逗号、双引号、换行符的连续字符)
local plain_field = C((1 - S(',"\r\n'))^0)

-- 规则 B: 引号包裹字段 (支持原生零临时表脱壳转义 "" -> ")
-- Cs (替换捕获) 配合 / 能够在 LPeg 匹配层面直接完成符号清洗，杜绝 string.gsub 产生的内存碎片
local escaped_quote = P('""') / '"'
local non_quote     = 1 - quote
local qcontent      = Cs((escaped_quote + non_quote)^0)
local quoted_field  = quote * qcontent * quote

-- 单元格字段综合规则 (优先匹配引号包裹字段，若不匹配则视为普通字段)
local field       = quoted_field + plain_field

-- 单行记录组装规则 (标准 CSV 单行：首字段 + 0到多个“逗号+字段”)
local record      = Ct(field * (comma * field)^0)

-- =====================================================================================
-- 【核心杀招：幽灵空行封杀 & 防零字符死循环 & 防静默截断】
-- =====================================================================================
-- 1. 负向前瞻断言 -(nl + -1)：
--    解决 0 字符可匹配陷阱。如果当前游标正对着换行符或文件结尾(EOF)，说明眼前是个纯空行或文件终点！
--    在起手瞬间直接拒绝匹配，绝对不给 record 零宽匹配生成 {""} 幽灵行的任何机会。
local valid_record = -(nl + -1) * record

-- 2. 标准行 (std_record)：
--    有效记录 + 1到多个连续换行符 (nl^1 化身海绵，顺便吞吃行尾所有多余空行)。
--    【编译保护】：因为 nl^1 静态保证了每次匹配至少消耗 1 个换行字符！
--    所以将它放入 ^0 循环中时，LPeg 绝对不会再报 "may accept empty string" 错误！
local std_record   = valid_record * nl^1

-- 3. 尾部行 (tail_record)：
--    有效记录 + 文件末尾 (-1)。专门捕获最后一行没有结尾换行符的特殊情况。
--    【防漏保护】：因为它使用 ^-1 (最多只匹配一次，不是无限循环)，所以允许零宽结尾！
local tail_record  = valid_record * -1

-- 4. 终极自适应主文法树：
--    nl^0吃掉头部空行 -> 循环匹配标准行 -> 匹配可选的无换行尾行 -> 锚定EOF防截断
--    * -1 为核心安全锁：要求状态机必须 100% 无损匹配完整个字符串，
--    若中途存在未闭合的引号或严重语法断裂，立刻报错返回 nil，彻底杜绝隐式截断！
local csv_grammar  = Ct( nl^0 * std_record^0 * tail_record^-1 ) * -1


-- =====================================================================================
-- 第二部分：面向对象 (OO) 元表与无损序列化辅助逻辑
-- =====================================================================================
local csv_mt = {}
csv_mt.__index = csv_mt

--- [内部辅助函数] 序列化单个单元格字段为标准 CSV 规范格式
--- @param val any 需要格式化的字段值
--- @return string 规范化并转义后的 CSV 字段文本
local function escape_csv_field(val)
    local str = tostring(val or "")
    -- 若字段包含逗号、双引号或换行符，必须进行外层双引号包裹，并将内部双引号转义为 ""
    if str:find('[,"\r\n]') then
        return '"' .. str:gsub('"', '""') .. '"'
    end
    return str
end

--- [元方法] 当调用 tostring(csv_obj) 或进行文件写入时，自动将二维 Table 无损还原为标准 CSV 文本
--- @return string 格式化后的标准多行 CSV 字符串
function csv_mt:__tostring()
    local out = {}
    for i = 1, #self do
        local row = self[i]
        if type(row) == "table" then
            local row_out = {}
            for j = 1, #row do
                row_out[j] = escape_csv_field(row[j])
            end
            out[i] = table_concat(row_out, ",")
        end
    end
    -- 按照工业规范，CSV 文件结尾应保持一个标准的换行符
    return table_concat(out, "\n") .. "\n"
end


-- =====================================================================================
-- 第三部分：业务调用与数据操作方法 (OO API)
-- =====================================================================================

--- [核心解析接口] 解析 CSV 格式字符串并高效追加到当前实例对象中
--- 该设计支持流式追加与分片加载，适合处理大型网络数据块
--- @param s string 待解析的 CSV 原始文本
--- @return table|nil csv_obj 成功则返回挂载了方法的自身，失败则返回 nil
--- @return string|nil err_msg 解析失败时的详细语法诊断描述
function csv_mt:parse_string(s)
    if type(s) ~= "string" or s == "" then
        return self
    end

    local parsed_rows = lpeg.match(csv_grammar, s)
    if not parsed_rows then
        return nil, "[LPeg Parse Error] CSV 语法严重断裂：发现未闭合的双引号、错乱转义或文件格式损坏！"
    end

    -- 将 LPeg 生成的新行数据高效合并到当前对象末尾
    local start_idx = #self
    for i, row in ipairs(parsed_rows) do
        self[start_idx + i] = row
    end

    return self
end

--- [内部辅助函数] 无状态迭代器核心驱动
--- 依靠泛型 for 的底层寄存器状态控制，避免每次迭代生成闭包和 upvalue，完全释放 GC 压力
local function read_line_stateless(t, index)
    index = index + 1
    local row = t[index]
    if not row then return nil end
    -- 注意：Lua 的泛型 for 要求第一个返回值为控制变量 (即当前行号 index)
    return index, unpack(row)
end

--- [业务方法] 极速无状态迭代器，专为大数据量泛型 for 循环打造
--- 用法示例: for row_idx, id, name, val in my_csv:lines() do ... end
--- @return function 迭代器驱动函数
--- @return table 实例自身
--- @return number 初始游标
function csv_mt:lines()
    return read_line_stateless, self, 0
end

--- [业务方法] 向当前表格尾部追加一行新数据
--- @param t table 必须是一个数组型的 Lua Table，例如: {"1002", "测试道具", "99"}
function csv_mt:insert(t)
    if type(t) == 'table' then
        table_insert(self, t)
    else
        error(string_format('csv:insert expected table row, got %s', type(t)), 2)
    end
end

--- [业务方法] 对当前表格内的数据行进行排序
--- @param func function|nil 排序比较函数。若留空，默认按照第一列(通常为主键ID)的升序排列
function csv_mt:sort(func)
    func = func or function (a, b) 
        return (a[1] or "") < (b[1] or "") 
    end
    table_sort(self, func)
end

--- [业务方法] 将当前表格内容以严谨的二进制覆盖模式持久化保存到本地硬盘
--- @param filepath string 目标文件的物理保存路径
--- @return boolean success 是否成功写入
--- @return string|nil error_msg 失败时的详细错误描述
function csv_mt:write(filepath)
    -- 强制采用 "wb" 二进制写入模式，杜绝 Windows 平台对 \n 自动转义篡改为 \r\n 的隐式破坏
    local f, err = io_open(filepath, 'wb')
    if f then
        f:write(tostring(self))
        f:close()
        return true
    else
        return false, string_format("[LPeg IO Error] 无法写入文件 '%s': %s", tostring(filepath), tostring(err))
    end
end

--- [业务方法] 格式化输出当前 CSV 结构到控制台，便于开发调试与直观核对
function csv_mt:print()
    for row_idx, row in ipairs(self) do
        if type(row) == "table" then
            print(string_format("Row %d: %s", row_idx, table_concat(row, " | ")))
        else
            print(string_format("Row %d: %s", row_idx, tostring(row)))
        end
    end
end


-- =====================================================================================
-- 第四部分：模块静态工厂接口 (静态 API 导出)
-- =====================================================================================
local csv = {}

--- [工厂方法] 创建一个全新的、空的 CSV 实例对象
--- @return table csv_obj 具有完整面向对象方法的空数据对象
function csv.new()
    return setmetatable({}, csv_mt)
end

--- [静态接口] 一步到位解析多行 CSV 格式原始字符串并返回标准实例
--- @param s string 内存中的 CSV 文本字符串
--- @return table|nil csv_obj 成功返回对象，语法断裂则返回 nil
--- @return string|nil err_msg 失败时的错误原因
function csv.parse_string(s)
    local obj = csv.new()
    return obj:parse_string(s)
end

--- [静态接口] 严谨地从磁盘加载并完整解析指定的本地 CSV 物理文件
--- @param filepath string 本地 CSV 文件的物理路径
--- @return table|nil csv_obj 成功返回对象，失败返回 nil
--- @return string|nil err_msg 失败时的详细原因描述
function csv.open(filepath)
    -- 强制采用 "rb" 二进制安全模式读取，保证文件流原汁原味投喂给 LPeg 状态机
    local f, err = io_open(filepath, "rb")
    if not f then
        return nil, string_format("[LPeg IO Error] 无法读取文件 '%s': %s", tostring(filepath), tostring(err))
    end
    
    -- 一次性高吞吐量将整个文件内容加载到内存中匹配，在处理大表时具有极高的 I/O 效率
    local s = f:read('*a')
    f:close()
    
    return csv.parse_string(s)
end

--- [工具方法] 高效集合运算：快速找出 csv2 中存在但 csv1 中不存在的“新增行数据”
--- 核心采用哈希映射结构，将算法复杂度从传统的双重循环 O(N*M) 降至线性 O(N+M)
--- @param csv1 table 基准对照老表
--- @param csv2 table 待比对的新表
--- @return table diff_table 仅包含新增数据行的全新 CSV 实例
function csv.diff(csv1, csv2)
    local t = csv.new()
    local lookup_set = {}
    
    -- 为原表的第一列(主键键值)建立 O(1) 极速查找哈希索引集
    for _, v1 in ipairs(csv1) do
        if type(v1) == "table" and v1[1] ~= nil then 
            lookup_set[v1[1]] = true 
        end
    end
    
    -- 线性扫描新表，快速筛出未曾记录过的新行并插入结果集
    for _, v2 in ipairs(csv2) do
        if type(v2) == "table" and (v2[1] == nil or not lookup_set[v2[1]]) then
            t:insert(v2)
        end
    end
    
    return t
end

-- 兼容老版本的调用习惯：保留 parse 作为 parse_string 的较短别名
csv.parse = csv.parse_string

return csv