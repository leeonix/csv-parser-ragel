# 🚀 High-Performance Ragel CSV Parser & Ecosystem

![Language](https://img.shields.io/badge/Language-C89%20%2F%20Lua%20%2F%20Ragel-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Win32%20%2F%20Linux-green.svg)
![Build](https://img.shields.io/badge/Build-Premake5%20%2F%20VS2010%20%2F%20GCC-brightgreen.svg)
![License](https://img.shields.io/badge/License-MIT-orange.svg)

本项目是一个工业级、极致性能的 **纯 Ragel 状态机 CSV 解析引擎 (`csv_parser`)**，并围绕该引擎构建了多线程安全的 **Lua 5.1+ C-API 绑定库** 以及 **Total Commander Lister (`.wlx`) 极速预览插件**。

项目专注于解决游戏服务器海量配置表（如 3000+ 行带有复杂正则、网址、双重转义引号的敏感词/屏蔽词库）的极速加载、零 GC 消耗清洗，以及大文件在桌面端的毫秒级无损可视化预览。

---

## ✨ 核心架构亮点

### 1. 纯状态机驱动与零拷贝洗净 (Core Engine)
* **LL(1) 纯转移指令网络**：彻底抛弃 Ragel 传统的 Scanner (`|* ... *|`) 回溯模式，使用标准进入 (`>`)、离开 (`%`) 与立即动作，结合 `-G2` 生成底层 `goto` 跳转代码，将 CPU 指令流与寄存器缓存压榨至极限，内存解析耗时仅需**微秒级 (μs)**。
* **快慢指针原地脱壳 (Zero-Copy Unescape)**：针对 CSV 中棘手的 `""` 转义（如 `""http://xxx.com/""`），独创在原生读取 Buffer 上通过快慢指针**原地覆盖覆写**的算法。完全不申请临时堆内存，**零 Malloc 碎块、零 GC 压力**。
* **100% C89 / VS2010 严格兼容**：所有变量声明严格置于作用域块顶部，消除了跨平台编译的所有警告与字符集（UTF-8 with BOM）报错。

### 2. 多线程安全 Lua 绑定 (Lua Ecosystem)
* **TLS 线程局部存储桥接**：在不需要修改底层原有参数回调接口的前提下，通过 C 语言 TLS（`__thread` / `__declspec(thread)`）优雅传递 `lua_State*` 上下文，做到**绝对的多线程并发加载安全**。
* **严格栈深度控制**：在 C 胶水层 (`csv_core.c`) 底层直接构建 Lua 二维表，内置精准的 `lua_gettop` 与 `lua_pop` 收割机制，处理数万列宽表也**绝不触发栈溢出 (Stack Overflow)**。
* **优雅的面向对象封装 (`csv.lua`)**：上层提供符合 Lua 习惯的 OOP 元表支持，内置解构迭代器 `lines()`、按列定制排序 `sort()`，以及基于哈希表 O(N+M) 极速对比的 `diff()` 工具。

### 3. Total Commander 极速插件 (`wlx_csv`)
* **告别 Web/Electron 臃肿**：在 TC 中按下 `F3` 或 `Ctrl+Q`，数万行大表毫秒级直接渲染为 Win32 原生 ListView 控件。
* **表头动态自适应扩展**：打破旧版“仅在第一行建列”的死板限制。解析过程中只要后续数据行遇到更大列号，ListView 立即自动追加新表头，保证数据**不丢列、不越界**。
* **原生无损呈现与导出**：表格内直接展示底层的脱壳干净文本（不再带有丑陋的双重引号），并支持多行选中一键复制为标准 CSV 格式 (`lc_copy`)。

---

## 📦 仓库目录结构

```text
csv-parser-ragel/
├── src/
│   ├── csv_parser.rl    # Ragel 状态机语法规则源文件
│   ├── csv_parser.c     # Ragel -G2 编译生成的极致性能 C 目标代码
│   └── csv_parser.h     # 核心 C 语言导出头文件
├── lua/
│   ├── csv_core.c       # Lua C-API 胶水层 (TLS 线程安全与栈控制)
│   └── csv.lua          # Lua 面向对象上层封装模块
├── wlx/
│   ├── wlx_csv.c        # Total Commander Lister 插件核心逻辑
│   ├── listplug.h       # TC Lister Plugin SDK 头文件
│   └── listplug.def     # DLL 导出符号定义
├── test/
│   └── test.c           # C 语言基准测试与命令行检验程序
└── Premake5.lua         # 跨平台自动化构建脚本

```

---

## 🛠️ 构建与编译

本项目采用 **Premake5** 进行跨平台工程管理，默认支持 Visual Studio 与 Make / GCC 体系。

### 1. 生成工程文件

在项目根目录下打开命令行，根据你的目标开发环境执行：

```bash
# 生成 Visual Studio 2010 解决方案 (.sln)
premake5 vs2010

# 或生成 Visual Studio 2019 / 2022 解决方案
premake5 vs2022

# 或生成 GNU Makefile (Linux / macOS)
premake5 gmake2

```

### 2. 重新编译 Ragel 状态机 (可选)

如果你修改了 `src/csv_parser.rl` 中的文法规则，请使用 Ragel 工具将生成的 C 源码重新覆写：

```bash
ragel -G2 -C src/csv_parser.rl -o src/csv_parser.c

```

*(注：项目仓库内已包含由 Ragel 生成的最新版 `csv_parser.c`，若不修改语法规则，无需安装 Ragel 即可直接编译 C/C++ 代码)*。

---

## 💻 快速上手指南

### Lua 脚本调用示例

将编译生成的模块（`core.dll` 或 `core.so` 放入 `lua/csv/` 目录中），配合 `csv.lua` 即可获得极其丝滑的加载体验：

```lua
local csv = require 'csv'

-- 1. 极速打开并解析本地文件（如 3000+ 行游戏敏感词库）
local my_table = csv.open("dirty_words.csv")
print("成功加载配置表，总行数: ", #my_table)

-- 2. 使用内建方法格式化打印到控制台
my_table:print()

-- 3. 使用极速解构迭代器遍历数据
for id, word, replace_str in my_table:lines() do
    if id == "10086" then
        print("找到敏感词条目:", word)
    end
end

-- 4. 自定义排序：按第一列 ID 倒序排列
my_table:sort(function(a, b) 
    return (tonumber(a[1]) or 0) > (tonumber(b[1]) or 0) 
end)

-- 5. 插入新行并写回磁盘文件
my_table:insert({"99999", "外挂自动打怪", "*"})
my_table:write("dirty_words_latest.csv")

```

### C 语言底层调用示例

```c
#include <stdio.h>
#include "csv_parser.h"

/* 定义极速内存回调：field 已由底层完成零拷贝脱壳并在末尾置 '\0' */
static void on_my_cell(void *ctx, int row_idx, int col_idx, const char *field, size_t field_len) {
    printf("Row: %d, Col: %d, Text: [%s], Len: %zu\n", 
           row_idx, col_idx, field, field_len);
}

int main() {
    /* 直接调用物理文件读取接口，内部自动 fseek 动态分配精准缓冲 */
    int total_rows = csv_parse_file("config/data.csv", on_my_cell, NULL);
    
    if (total_rows < 0) {
        printf("解析错误：文件不存在或发生严重的语法断裂！\n");
    } else {
        printf("完美无损解析完成！共处理 %d 行数据。\n", total_rows);
    }
    return 0;
}

```

---

## 📊 性能表现与设计对比

在实际游戏开发场景（3400+ 行、8100+ 个单元格、包含大量连续转义双引号 `""` 与 URL 链接的词库表）下的实测对照：

| 评估维度 | 传统 Lua / Python 正则切片 | Ragel 2.0 纯状态机引擎 (`csv_parser`) |
| --- | --- | --- |
| **整体 I/O 与解析耗时** | ~50 ms - 200 ms | **~0.5 ms (500 μs)** |
| **纯内存文法状态转移耗时** | ~10 ms | **< 100 μs (微秒级)** |
| **内存分配与 GC 碎块** | 随单元格数量激增，产生数万个微型字符串堆碎块 | **零堆碎块 (快慢指针原生内存覆写)** |
| **多线程并发安全性** | 需依赖全局锁或独立虚拟机实例 | **原生线程安全 (TLS 局部上下文闭包)** |

---

## 📄 许可证 (License)

MIT License.

Authored & Maintained by **LeeoNix**.

*Dedicated to high-performance C programming and old-school Win32 hacker aesthetics.*
