
#line 1 "../parser/csv_parser.rl"
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


#line 83 "../parser/csv_parser.c"
static const int csv_parser_start = 6;
static const int csv_parser_first_final = 6;
static const int csv_parser_error = 0;

static const int csv_parser_en_main = 6;


#line 170 "../parser/csv_parser.rl"


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
    
#line 112 "../parser/csv_parser.c"
	{
	( s->cs) = csv_parser_start;
	}

#line 194 "../parser/csv_parser.rl"
    
#line 115 "../parser/csv_parser.c"
	{
	if ( p == pe )
		goto _test_eof;
	switch ( ( s->cs) )
	{
case 6:
	switch( (*p) ) {
		case 10: goto tr11;
		case 13: goto tr12;
		case 34: goto tr13;
		case 44: goto tr14;
	}
	goto tr10;
tr10:
#line 100 "../parser/csv_parser.rl"
	{ 
        s->ts = p;       /* 踩点：记录字段起始内存指针 */
        s->is_quoted = 0;  /* 标记：当前为纯裸文本字段 */
    }
	goto st7;
tr16:
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
#line 100 "../parser/csv_parser.rl"
	{ 
        s->ts = p;       /* 踩点：记录字段起始内存指针 */
        s->is_quoted = 0;  /* 标记：当前为纯裸文本字段 */
    }
	goto st7;
st7:
	if ( ++p == pe )
		goto _test_eof7;
case 7:
#line 148 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 10: goto tr11;
		case 13: goto tr12;
		case 34: goto st0;
		case 44: goto tr14;
	}
	goto st7;
tr11:
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
	goto st8;
tr17:
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
	goto st8;
st8:
	if ( ++p == pe )
		goto _test_eof8;
case 8:
#line 219 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 10: goto tr17;
		case 13: goto tr18;
		case 34: goto tr19;
		case 44: goto tr20;
	}
	goto tr16;
tr12:
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
	goto st1;
tr18:
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
	goto st1;
st1:
	if ( ++p == pe )
		goto _test_eof1;
case 1:
#line 290 "../parser/csv_parser.c"
	if ( (*p) == 10 )
		goto st8;
	goto st0;
st0:
( s->cs) = 0;
	goto _out;
tr4:
#line 106 "../parser/csv_parser.rl"
	{ s->has_escapes = 1; }
	goto st2;
tr13:
#line 107 "../parser/csv_parser.rl"
	{ 
        s->ts = p + 1;   /* 踩点：跳过最外侧起始左双引号 '"' */
        s->is_quoted = 1;  /* 标记：当前为双引号包围字段 */
        s->has_escapes = 0;/* 初始化：暂未发现内部包含 "" 转义 */
    }
	goto st2;
tr19:
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
#line 107 "../parser/csv_parser.rl"
	{ 
        s->ts = p + 1;   /* 踩点：跳过最外侧起始左双引号 '"' */
        s->is_quoted = 1;  /* 标记：当前为双引号包围字段 */
        s->has_escapes = 0;/* 初始化：暂未发现内部包含 "" 转义 */
    }
	goto st2;
st2:
	if ( ++p == pe )
		goto _test_eof2;
case 2:
#line 321 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 0: goto st0;
		case 34: goto st9;
	}
	goto st2;
tr5:
#line 106 "../parser/csv_parser.rl"
	{ s->has_escapes = 1; }
	goto st9;
st9:
	if ( ++p == pe )
		goto _test_eof9;
case 9:
#line 333 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 10: goto tr11;
		case 13: goto tr12;
		case 34: goto st3;
		case 44: goto tr14;
	}
	goto st0;
st3:
	if ( ++p == pe )
		goto _test_eof3;
case 3:
	switch( (*p) ) {
		case 0: goto st0;
		case 34: goto tr5;
	}
	goto tr4;
tr14:
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
	goto st10;
tr20:
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
	goto st10;
st10:
	if ( ++p == pe )
		goto _test_eof10;
case 10:
#line 413 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 10: goto tr11;
		case 13: goto tr12;
		case 34: goto tr23;
		case 44: goto tr14;
	}
	goto tr22;
tr22:
#line 100 "../parser/csv_parser.rl"
	{ 
        s->ts = p;       /* 踩点：记录字段起始内存指针 */
        s->is_quoted = 0;  /* 标记：当前为纯裸文本字段 */
    }
	goto st11;
st11:
	if ( ++p == pe )
		goto _test_eof11;
case 11:
#line 430 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 10: goto tr11;
		case 13: goto tr12;
		case 34: goto st0;
		case 44: goto tr14;
	}
	goto st11;
tr8:
#line 106 "../parser/csv_parser.rl"
	{ s->has_escapes = 1; }
	goto st4;
tr23:
#line 107 "../parser/csv_parser.rl"
	{ 
        s->ts = p + 1;   /* 踩点：跳过最外侧起始左双引号 '"' */
        s->is_quoted = 1;  /* 标记：当前为双引号包围字段 */
        s->has_escapes = 0;/* 初始化：暂未发现内部包含 "" 转义 */
    }
	goto st4;
st4:
	if ( ++p == pe )
		goto _test_eof4;
case 4:
#line 451 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 0: goto st0;
		case 34: goto st12;
	}
	goto st4;
tr9:
#line 106 "../parser/csv_parser.rl"
	{ s->has_escapes = 1; }
	goto st12;
st12:
	if ( ++p == pe )
		goto _test_eof12;
case 12:
#line 463 "../parser/csv_parser.c"
	switch( (*p) ) {
		case 10: goto tr11;
		case 13: goto tr12;
		case 34: goto st5;
		case 44: goto tr14;
	}
	goto st0;
st5:
	if ( ++p == pe )
		goto _test_eof5;
case 5:
	switch( (*p) ) {
		case 0: goto st0;
		case 34: goto tr9;
	}
	goto tr8;
	}
	_test_eof7: ( s->cs) = 7; goto _test_eof; 
	_test_eof8: ( s->cs) = 8; goto _test_eof; 
	_test_eof1: ( s->cs) = 1; goto _test_eof; 
	_test_eof2: ( s->cs) = 2; goto _test_eof; 
	_test_eof9: ( s->cs) = 9; goto _test_eof; 
	_test_eof3: ( s->cs) = 3; goto _test_eof; 
	_test_eof10: ( s->cs) = 10; goto _test_eof; 
	_test_eof11: ( s->cs) = 11; goto _test_eof; 
	_test_eof4: ( s->cs) = 4; goto _test_eof; 
	_test_eof12: ( s->cs) = 12; goto _test_eof; 
	_test_eof5: ( s->cs) = 5; goto _test_eof; 

	_test_eof: {}
	if ( p == eof )
	{
	switch ( ( s->cs) ) {
	case 7: 
	case 8: 
	case 9: 
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
	break;
	case 10: 
	case 11: 
	case 12: 
#line 117 "../parser/csv_parser.rl"
	{
        /* [C89 规范] 动作块内部同样需要遵循 C89 守则，把局部变量声明提至第一行 */
        size_t len = 0;
        
        if (s->ts && p > s->ts) {
            len = (size_t)(p - s->ts);
            /* 若是引号包裹字段，进入本动作时 fpc 正好踩在闭合右双引号上
             * 此时 len - 1 刚好自动剥离尾部右双引号，完成两端完美脱皮 */
            if (s->is_quoted) {
                len = (size_t)(p - s->ts - 1);
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
    }
#line 145 "../parser/csv_parser.rl"
	{
        s->row_idx++;
        s->col_idx = 0;
    }
	break;
#line 538 "../parser/csv_parser.c"
	}
	}

	_out: {}
	}

#line 195 "../parser/csv_parser.rl"

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