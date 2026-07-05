# 🚀 High-Performance Ragel CSV Parser & Total Commander Lister Plugin

![Language](https://img.shields.io/badge/Language-C89%20%2F%20Ragel-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Win32%20%2F%20Linux%20%2F%20Lua-green.svg)
![Build](https://img.shields.io/badge/Build-VS2010%20%2F%20GCC-brightgreen.svg)
![License](https://img.shields.io/badge/License-MIT-orange.svg)

本项目包含一个工业级、高性能的纯 **Ragel 状态机 CSV 解析引擎** (`csv_parser`)，以及基于该引擎研发的 **Total Commander Lister (`.wlx`) 预览插件** (`wlx_csv`)。

本项目最早始于 2013 年，于 2026 年进行了彻底的底层重构与现代工程化升级。专为极速吞吐、复杂游戏配置表（如 3000+ 行带有复杂双引号、正则、网址的敏感词/屏蔽词库）加载、以及大文件瞬间可视化预览而设计。

---

## 目录 (Table of Contents)

- [✨ 核心特性 (Features)](#-核心特性-features)
  - [1. 纯状态机 CSV 解析引擎 (csv_parser)](#1-纯状态机-csv-解析引擎-csv_parser)
  - [2. Total Commander 查看器插件 (wlx_csv)](#2-total-commander-查看器插件-wlx_csv)
- [📦 项目结构 (Project Structure)](#-项目结构-project-structure)
- [🛠️ 编译与构建 (Build & Compile)](#-编译与构建-build--compile)
  - [编译 Ragel 状态机](#1-编译-ragel-状态机)
  - [使用 MSVC / VS2010 编译](#2-使用-msvc--vs2010-编译)
- [💻 API 与接入指南 (API & Usage)](#-api-与接入指南-api--usage)
  - [C 语言基础调用](#c-语言基础调用)
  - [绑定 Lua 虚拟机 / 前缀树](#绑定-lua-虚拟机--前缀树)
- [📊 性能表现 (Performance)](#-性能表现-performance)
- [📄 许可证 (License)](#-许可证-license)

---

## ✨ 核心特性 (Features)

### 1. 纯状态机 CSV 解析引擎 (`csv_parser`)

* 🔥 **纯状态机驱动 (Pure LL(1) State Machine)**：彻底摒弃 Ragel 的 Scanner (`|* ... *|`) 模式与冗余回溯指令。使用标准进入 (`>`)、离开 (`%`) 与立即 (`%`) 动作，极致压榨 CPU 指令流水线与寄存器缓存，内核解析耗时压至**微秒级 (μs)**！
* ⚡ **零拷贝原地清洗 (Zero-Copy In-Place Unescape)**：针对复杂 CSV 字段中嵌套的 `""` 转义（如 `""http://xxx.com/""`），独创**快慢指针原地洗净算法**。在底层 Buffer 内存中直接覆盖替换为标准 `"`，**零临时字符串分配、零 GC 压力、零 Malloc 碎块**！
* 🛡️ **严格文法分流，编译零警告 (Zero Warnings)**：将“以 CRLF 结束的标准行 (`std_row`)”与“无换行的文件末尾尾行 (`tail_row`)”独立隔离定义，彻底消除了 Kleene 星号在零长度词上的无限循环警告；集成 `_first_final` 终态校验，能够精准识别文件截断或语法破损。
* 💾 **动态堆缓冲机制**：废除老旧的 4KB 静态缓冲限制，采用 `fseek/ftell` 动态探知文件大小并一次性分配恰好够用的内存块，彻底解除了大字段（多行文本、广告词、内嵌 JSON）引发的卡死雷区。
* 🔌 **线程安全与上下文闭包 (`void *ctx`)**：API 开放自定义上下文指针，可多线程并发实例加载，无缝传递 `lua_State*` 或 AC 自动机 / Trie 前缀树根指针。
* 🏛️ **100% C89 & VS2010 兼容**：严格遵循 ANSI C (C89) 变量顶格声明规范，源文件采用 `UTF-8 with BOM` 签名，在 MSVC / VS2010 下编译**零报错、零乱码**。

### 2. Total Commander 查看器插件 (`wlx_csv`)

* ⚡ **极速大表加载**：在 Total Commander 中按下 `F3` 或 `Ctrl+Q`，数万行数据瞬间渲染成原生 Win32 ListView，拒绝 Web / Electron 方案的臃肿迟钝。
* 📐 **表头列数自适应动态扩展**：打破旧版“仅靠第一行建列”的死板限制。在解析过程中，只要后续数据行遇到更宽的列，ListView 会立刻自动创建新表头，保证字段**不丢列、不越界**。
* 🎨 **原生无损转义展示**：借助底层原地脱壳引擎，表格内直接显示洗净后的纯粹文本，不再出现丑陋的双重双引号；内置自适应 UTF-8 到 Win32 ANSI/ACP 编码转换，中文不乱码。
* ↕️ **智能排序与极速列复制**：自动根据单元格内容长度计算并撑开初始列宽；支持点击表头正倒序快速排序，支持选中多行列数据并一键复制为标准 CSV 文本格式 (`lc_copy`)。

---

## 📦 项目结构 (Project Structure)

```text
csv-parser-ragel/
├── src/
│   ├── csv_parser.rl    # Ragel 状态机语法定义与核心引擎源码
│   ├── csv_parser.c     # 由 Ragel -G2 生成的高性能 C 语言目标文件
│   └── csv_parser.h     # 外部 C/C++ / Lua 调用的公共头文件
├── test/
│   ├── test.c           # C89 规范的命令行基准测试与检验程序
│   └── dirty_words.csv  # 游戏屏蔽词/非法词汇测试表 (3000+ 行复杂配置)
├── wlx/
│   ├── wlx_csv.c        # Total Commander Lister (.wlx) 插件核心实现
│   └── listplug.h       # Total Commander Lister Plugin SDK 头文件
└── README.md            # 项目说明文档