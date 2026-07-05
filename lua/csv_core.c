/*
 * =====================================================================================
 * Filename:  csv_core.c
 * Description:  Ragel CSV Parser Lua Core Binding (High Performance & Zero-Copy)
 * Version:  3.0 (C89 Strictly Compliant)
 * =====================================================================================
 */

#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include "lua_buffer.h"
#include "csv_parser.h"

#if LUA_VERSION_NUM >= 502
#ifndef lua_objlen
#define lua_objlen lua_rawlen
#endif
#endif

/* 
 * 解析上下文结构体：用于向 Ragel 回调函数传递 Lua 状态机及行级追踪状态
 */
typedef struct {
    lua_State *L;
    int root_idx;       /* 根 Table 在 Lua 栈中的绝对索引位置 */
    int last_row_idx;   /* 追踪当前处理的最后一行行号 (0-indexed) */
} parse_ctx_t;

/*
 * =====================================================================================
 * 核心回调：将 Ragel 洗净的字段原地压入 Lua 2D Table
 * =====================================================================================
 */
static void lua_csv_cell_cb(void *ctx, int row_idx, int col_idx, const char *field, size_t field_len)
{
    parse_ctx_t *pctx = (parse_ctx_t *)ctx;
    lua_State *L = pctx->L;

    /* 1. 换行检测：如果当前 Ragel 行号与记录的最后行号不一致，说明进入了新的一行 */
    if (row_idx != pctx->last_row_idx) {
        lua_newtable(L);
        /* root_table[row_idx + 1] = new_table (Lua 数组从 1 开始) */
        lua_rawseti(L, pctx->root_idx, row_idx + 1);
        pctx->last_row_idx = row_idx;
    }

    /* 2. 获取当前行子表，并填充当前列字段 */
    lua_rawgeti(L, pctx->root_idx, row_idx + 1);
    lua_pushlstring(L, field, field_len);
    /* row_table[col_idx + 1] = field_string */
    lua_rawseti(L, -2, col_idx + 1);

    /* 3. 平衡 Lua 栈，弹出当前行子表 */
    lua_pop(L, 1);
}

/*
 * =====================================================================================
 * 接口：对应 csv.lua 中的 csv_mt.parse_string
 * =====================================================================================
 */
static int csv_parse(lua_State *L)
{
    size_t len;
    const char *str;
    parse_ctx_t ctx;
    int total_rows;

    str = luaL_checklstring(L, 2, &len);
    lua_settop(L, 1);
    luaL_checktype(L, 1, LUA_TTABLE);

    /* 初始化上下文 */
    ctx.L = L;
    ctx.root_idx = 1;      /* 对应传入的空挂载 Table */
    ctx.last_row_idx = -1; /* 初始化为 -1 确保首行顺利触发创建 */

    /* 投喂给高性能 Ragel 缓冲区解析引擎 */
    total_rows = csv_parse_buffer(str, len, lua_csv_cell_cb, &ctx);
    if (total_rows < 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "Parse error");
        return 2;
    }

    return 1;
}

/*
 * =====================================================================================
 * 以下完全保留您原有库的序列化及迭代器功能 (保持行为绝对一致)
 * =====================================================================================
 */
static void addfield(lua_State *L, buffer_t *b, int i)
{
    const char *str;
    int len, k;
    unsigned char need_quotes = 0;

    lua_rawgeti(L, 2, i);
    if (!lua_isstring(L, -1))
        luaL_error(L, "invalid value (%s) at index %d in table for 'concat'", luaL_typename(L, -1), i);
    
    str = lua_tolstring(L, -1, &len);

    for (k = 0; k < len; k++) {
        unsigned char c = (unsigned char)str[k];
        if (c == ',' || c == '"' || c == '\n' || c == '\r') {
            need_quotes = 1;
            break;
        }
    }

    if (!need_quotes) {
        buffer_add_str(b, str, len);
    } else {
        buffer_add_char(b, '"');
        for (k = 0; k < len; k++) {
            if (str[k] == '"')
                buffer_add_char(b, '"');
            buffer_add_char(b, str[k]);
        }
        buffer_add_char(b, '"');
    }
    lua_pop(L, 1);
}

static int csv_tostring(lua_State *L)
{
    int i, j, last, len;
    buffer_t *b = new_buffer();
    luaL_checktype(L, 1, LUA_TTABLE);
    len = lua_objlen(L, 1);
    for (j = 1; j <= len; ++j) {
        lua_rawgeti(L, 1, j);
        luaL_checktype(L, 2, LUA_TTABLE);
        last = lua_objlen(L, 2);
        for (i = 1; i < last; ++i) {
            addfield(L, b, i);
            buffer_add_char(b, ',');
        }
        if (i == last)
            addfield(L, b, i);
        if (j < len)
            buffer_add_char(b, '\n');
        lua_settop(L, 1);
    }
    lua_pushlstring(L, b->buf, b->str_size);
    free_buffer(b);
    return 1;
}

static int read_line(lua_State *L)
{
#if LUA_VERSION_NUM >= 503
    lua_Integer j = luaL_checkinteger(L, 2);
#else
    int j = luaL_checkint(L, 2);
#endif
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_rawgeti(L, 1, ++j);
    if (lua_isnil(L, -1)) {
        return 0;
    } else {
        int i, e;
        int top = lua_gettop(L);
        luaL_checktype(L, top, LUA_TTABLE);
        e = lua_objlen(L, top) + 1;
        lua_pushinteger(L, j);
        for (i = 1; i < e; ++i) {
            lua_rawgeti(L, top, i);
        }
        return e;
    }
}

static int csv_lines(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushvalue(L, lua_upvalueindex(1));  /* return generator, */
    lua_pushvalue(L, 1);                    /* state, */
    lua_pushinteger(L, 0);                  /* and initial value */
    return 3;
}

LUALIB_API int luaopen_csv_core(lua_State *L)
{
    lua_createtable(L, 0, 4);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, csv_tostring);
    lua_setfield(L, -2, "__tostring");
    lua_pushcfunction(L, csv_parse);
    lua_setfield(L, -2, "parse_string");
    lua_pushcfunction(L, read_line);
    lua_pushcclosure(L, csv_lines, 1);
    lua_setfield(L, -2, "lines");
    return 1;
}