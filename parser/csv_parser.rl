/*
 * =====================================================================================
 * Filename:  csv_parser.rl
 * Description:  工业级高性能纯 Ragel CSV 解析器 (面向游戏服务器屏蔽词/非法词汇库清洗)
 * Version:  2.2 (Complete Annotated Edition & VS2010/C89 Strictly Compliant)
 * Compile:  ragel -G2 -C csv_parser.rl -o csv_parser.c
 * =====================================================================================
 *
 * 【核心设计与架构亮点】
 * 1. 纯状态机驱动 (Pure State Machine): 彻底抛弃了 Ragel 的 Scanner (|* ... *|) 模式，
 * 不生成 act 标记与回溯代码。利用进入(>)、离开(%)与立即(%)动作，极致榨取 CPU 指令流性能。
 * 2. 零 GC 原地清洗 (Zero-Copy In-Place Unescape): 针对屏蔽词库中带有 "" 转义的网址或复杂
 * 文本，利用快慢指针直接在底层 Buffer 内存中原地覆盖洗净，不申请任何临时堆内存。
 * 3. 严格 LL(1) 文法分流 (Zero Warnings): 把“严格以换行结尾的标准行 (std_row)”与“无换行
 * 的文件尾行 (tail_row)”隔开定义，彻底解决了 Kleene 星号无限循环零长度词的警告。
 * 4. 100% 兼容 VS2010 C89 标准: 所有局部变量声明严格置于块/函数的第一行，杜绝 C2143 报错。
 * 5. 线程安全与上下文闭包 (Thread-Safe & Context): 开放 void *ctx 参数，能够非常平滑地
 * 直接绑定 lua_State* 或敏感词前缀树 (Trie) 根节点指针，支持多线程并发加载配置表。
 * =====================================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "csv_parser.h"

/* 默认动态文件读取的初始缓冲大小 (8KB 已能应付 99% 的小型配置表，大文件会自动 malloc) */
#define INIT_BUF_SIZE 8192

/*
 * 内部扫描器上下文状态表
 * 仅在 C 函数执行期间驻留在 CPU 局部栈上，解析完成即刻释放，毫无持久化内存泄漏风险
 */
struct csv_parser_s {
    int cs;             /* Ragel 状态机当前语法状态指针 (Current State) */
    const char *ts;     /* 当前单元格字段在 Buffer 中的起始切片位置 (Token Start) */
    int row_idx;        /* 当前正在解析的行号 (从 0 开始自增) */
    int col_idx;        /* 当前正在解析的列号 (从 0 开始自增) */
    int is_quoted;      /* 语法标志位：当前字段是否被最外层的双引号 " ... " 包裹 */
    int has_escapes;    /* 语法标志位：当前带引号字段内部，是否遇到过被转义的双引号 "" */
};

/*
 * =====================================================================================
 * 内部核心算法：快慢指针原地清洗 "" 转义 (In-Place Unescape)
 * =====================================================================================
 * [原理说明]
 * 在标准 CSV 中，字段内嵌的双引号被写为 ""。在内存缓冲区中，"" 占据 2 个字节，而还原后的
 * 标准文本 " 仅占 1 个字节。这意味着，任何清洗后的文本长度永远小于或等于原始数据长度！
 * * [实现策略]
 * 利用快指针 (fast) 在前探路，慢指针 (slow) 在后覆写：
 * 1. 当快指针遇到连续两个 "" 时，慢指针写入一个 "，同时快指针直接向后跨跃 2 步；
 * 2. 遇到普通字符时，快指针的内容直接赋值给慢指针，两指针同步前进；
 * 3. 最终在慢指针末尾追加 '\0'，做到原地完美截断，全程零内存分配！
 * =====================================================================================
 */
static size_t clean_quoted_field(char *str, size_t len) {
    /* [C89 规范]：所有局部变量必须在函数最最开头声明！绝不能放在 if 判断语句后面！ */
    char *fast;
    char *slow;
    char *end;

    if (len == 0) return 0;
    
    fast = str;
    slow = str;
    end = str + len;
    
    while (fast < end) {
        /* 检测到 CSV 的转义双引号 ""，进行脱壳去重 */
        if (*fast == '"' && (fast + 1 < end) && *(fast + 1) == '"') {
            *slow++ = '"';
            fast += 2; 
        } else {
            *slow++ = *fast++;
        }
    }
    *slow = '\0'; /* 尾部追加安全终结符，方便下游 C/Lua 字符串 API 直接读取 */
    return (size_t)(slow - str);
}

%%{
    machine csv_parser;

    # =========================================================================
    # 显式绑定 Ragel 内部核心状态指针
    # =========================================================================
    # 必须显式申明将 Ragel 的 current state (cs) 和 token start (ts) 绑定到我们的
    # 自定义结构体中，否则 Ragel 生成的代码会默认去找全局或栈上的 cs/ts 局部变量
    variable cs s->cs;
    variable ts s->ts;

    # =========================================================================
    # 基础词法定义 (在 Ragel 机器区，转义字符严禁裸写，必须用单引号或方括号包裹)
    # =========================================================================
    CRLF = '\r'? '\n'; # 完美兼容 Windows (\r\n) 与 Linux/Unix (\n) 换行格式
    comma = ',';       # 逗号分隔符

    # 1. 普通非引号字段：只要不是逗号、换行符或双引号，一律作为普通连续文本吃进
    plain_field = [^,\r\n"]+ >{ 
        s->ts = fpc;       /* 踩点：记录字段起始内存指针 */
        s->is_quoted = 0;  /* 标记：当前为纯裸文本字段 */
    };

    # 2. 引号包裹字段：支持内部包含任意特殊字符（包括网址斜杠、逗号与换行），或连续的 ""
    quoted_content = ( [^"\0] | ('""' %{ s->has_escapes = 1; }) )*;
    quoted_field = '"' >{ 
        s->ts = fpc + 1;   /* 踩点：跳过最外侧起始左双引号 '"' */
        s->is_quoted = 1;  /* 标记：当前为双引号包围字段 */
        s->has_escapes = 0;/* 初始化：暂未发现内部包含 "" 转义 */
    } quoted_content '"' ; # 匹配最外侧闭合右引号

    # =========================================================================
    # 字段结束公共收割动作 (当遇到逗号分界、或行尾分界时立即触发)
    # 兼容普通字段、引号字段以及 "" 空字段三种形态
    # =========================================================================
    field = (plain_field | quoted_field | "") %{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && fpc > s->ts) {
            len = (size_t)(fpc - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(fpc - s->ts - 1);
            }
        }

        /* 仅当字段既被引号包裹，又遇到过 "" 转义时，才触发快慢指针极速洗净 */
        if (s->is_quoted && s->has_escapes && len > 0) {
            len = clean_quoted_field((char *)s->ts, len);
        }

        /* 触发用户传入的外部回调函数：将干干净净的敏感词注入前缀树或 Lua 表 */
        if (cb) {
            cb(ctx, s->row_idx, s->col_idx, s->ts ? s->ts : "", len);
        }
        
        s->col_idx++;      /* 列计数器自增 */
        s->ts = NULL;      /* 重置切片游标，准备迎接下一列 */
    };

    # 换行触发动作：行计数器自增，列计数器归零
    action on_row_end {
        s->row_idx++;
        s->col_idx = 0;
    }

    # =========================================================================
    # 彻底解决 Kleene Star 零长度死循环警告的文法分流架构
    # =========================================================================
    
    # [标准行 std_row] 强制要求以 CRLF 结束 (最少消耗 1 字节 '\n')
    # 因为该规则不可能消耗 0 字节，在外面加上无限循环 std_row* 时，Ragel 编译零警告！
    std_row = (field (comma field)* CRLF) %on_row_end;

    # [尾行 tail_row] 专为处理文件末尾既没有逗号也没写换行的最后一截残余数据
    # 强制要求至少包含一个逗号 (如 "a,") 或至少包含一个非空字段 (如 "敏感词")
    # 彻底解除了若文件尾部全空，状态机会凭空多回调一次幽灵空行的隐患！
    tail_row = (field (comma field)+ | (plain_field | quoted_field)) %on_row_end;

    # [主文法转移定义] 纯状态机转移定义 (Pure State Machine)
    # 整个 CSV 文件由 0 到多个标准换行行组成，结尾可跟随一个可选的无换行尾行
    main := std_row* tail_row? ;

    # 声明生成内部状态表与所有关键常量 (包括 csv_parser_first_final)
    # 注意：绝不能在这里加上 nofinal，否则会导致 C 代码由于找不到 _first_final 而报错！
    write data;
}%%

/*
 * =====================================================================================
 * 接口 1：内存数据块直接解析引擎 (Buffer Parse API)
 * =====================================================================================
 * 最适合场景：游戏服务器通过网络拉取或通过 mmap 加载配置表至内存后，调用本接口。
 * 返回值：成功返回顺利解析出来的总行数；若配置表语法存在严重损坏则返回 -1。
 * =====================================================================================
 */
int csv_parse_buffer(const char *buf, size_t len, csv_cell_cb cb, void *ctx) {
    /* [C89 规范]：所有的指针和结构体必须在第一行声明，严禁在 if 判断后声明！ */
    struct csv_parser_s parser;
    struct csv_parser_s *s = &parser;
    const char *p = buf;
    const char *pe = buf + len;
    const char *eof = pe;

    if (!buf || len == 0) return 0;

    memset(s, 0, sizeof(struct csv_parser_s));

    /* 触发 Ragel 内部变量初始化与核心执行网络 */
    %% write init;
    %% write exec;

    /*
     * 核心安全校验：判断状态机最终落点
     * 若 s->cs < csv_parser_first_final，说明配置表中遇到了违反 CSV LL(1) 语法的结构，
     * 例如双引号只有左括号没有闭合就直接到达了文件末尾，状态机卡在了中间或错误状态。
     */
    if (s->cs < csv_parser_first_final) {
        fprintf(stderr, "[CSV Parser Error] Fatal syntax error around row %d, col %d\n", 
                s->row_idx + 1, s->col_idx + 1);
        return -1;
    }

    return s->row_idx;
}

/*
 * =====================================================================================
 * 接口 2：本地物理文件读取封装 (File Parse API)
 * =====================================================================================
 * 最适合场景：本地开发或启动引擎时，读取本地的 /config/dirty_words.csv 文件。
 * 技术亮点：利用 ftell/fseek 探知文件总大小，动态申请恰好够用的内存堆，彻底终结了
 * 旧版本 4KB 静态缓冲一旦遇到超长过滤词就会直接报错退出的重大雷区！
 * =====================================================================================
 */
int csv_parse_file(const char *filepath, csv_cell_cb cb, void *ctx) {
    /* [C89 规范] 严格顶格声明变量 */
    FILE *f;
    long file_size;
    char *dyn_buf;
    size_t read_bytes;
    int total_rows;

    f = fopen(filepath, "rb");
    if (!f) {
        fprintf(stderr, "[CSV Parser Error] Failed to open file: %s\n", filepath);
        return -1;
    }

    /* 探查物理文件的绝对字节长度 */
    fseek(f, 0, SEEK_END);
    file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size <= 0) {
        fclose(f);
        return 0;
    }

    /* 动态分配堆缓冲内存 (+1 留给安全的 '\0' 终结符，保障内存越界安全) */
    dyn_buf = (char *)malloc(file_size + 1);
    if (!dyn_buf) {
        fprintf(stderr, "[CSV Parser Error] Out of memory when loading %s (%ld bytes)\n", 
                filepath, file_size);
        fclose(f);
        return -1;
    }

    read_bytes = fread(dyn_buf, 1, file_size, f);
    fclose(f);
    
    dyn_buf[read_bytes] = '\0'; /* 强制在末尾打上终结标记 */

    /* 把完整文件内存块投喂给核心解析器 */
    total_rows = csv_parse_buffer(dyn_buf, read_bytes, cb, ctx);
    
    /* 立即释放内存缓冲，用完即走，绝不给服务器增加 GC 负担 */
    free(dyn_buf);
    return total_rows;
}