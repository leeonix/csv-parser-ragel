/*
 * =====================================================================================
 * Filename:  lua/csv_core.c
 * Description: Lua C-API Binding for High-Performance Ragel CSV Parser
 * =====================================================================================
 */

#include <lua.h>
#include <lauxlib.h>
#include <string.h>

/* 引入你新写的核心解析器头文件 */
#include "csv_parser.h"

/* * Lua 上下文容器
 * 用于在回调中持有当前 Lua 虚拟机指针和结果表的栈索引
 */
typedef struct {
    lua_State *L;
    int result_table_idx; /* 二维大表 (row_table) 在栈中的绝对索引 */
} csv_lua_ctx_t;

/*
 * [核心回调] 被 csv_parser 触发
 * 每当解析器吐出一个单元格，此函数就会被调用。
 */
static void on_csv_cell(void *ctx, int row_idx, int col_idx, const char *field, size_t field_len) {
    csv_lua_ctx_t *ctx_ptr = (csv_lua_ctx_t *)ctx;
    lua_State *L = ctx_ptr->L;

    /* 1. 若是行起始 (col_idx == 0)，创建新行 Table */
    if (col_idx == 0) {
        /* 如果栈顶残留着上一行的 Table，清理掉它，保持栈深度稳定 */
        while (lua_gettop(L) > ctx_ptr->result_table_idx) {
            lua_pop(L, 1);
        }
        
        /* 创建新的行 Table 压入栈顶 */
        lua_newtable(L);
        /* 将行 Table 存入大表: result_table[row_idx + 1] = row_table */
        lua_pushvalue(L, -1); /* 复制一份留在栈顶 */
        lua_rawseti(L, ctx_ptr->result_table_idx, row_idx + 1);
    }

    /* 2. 填充单元格文本到当前行 Table (栈顶即为当前行 Table) */
    /* 使用 pushlstring 直接从 field 指针读取，无需额外拷贝 */
    lua_pushlstring(L, field, field_len);
    lua_rawseti(L, -2, col_idx + 1); /* -2 指向栈顶的行 Table */
}

/* * 导出接口: csv.core.parse_file(filepath)
 */
static int l_parse_file(lua_State *L) {
    const char *filepath = luaL_checkstring(L, 1);
    csv_lua_ctx_t ctx;
    
    ctx.L = L;

    /* 初始化结果大表 */
    lua_newtable(L);
    ctx.result_table_idx = lua_gettop(L);

    /* 调用新版 Ragel 解析引擎 */
    csv_parse_file(filepath, on_csv_cell, &ctx);

    /* 返回大表 */
    return 1;
}

/* * 导出接口: csv.core.parse_string(str)
 */
static int l_parse_string(lua_State *L) {
    size_t len;
    const char *str = luaL_checklstring(L, 1, &len);
    csv_lua_ctx_t ctx;

    ctx.L = L;

    /* 初始化结果大表 */
    lua_newtable(L);
    ctx.result_table_idx = lua_gettop(L);

    /* 调用新版 Ragel 解析引擎 */
    csv_parse_buffer(str, len, on_csv_cell, &ctx);

    return 1;
}

/* 模块注册表 */
static const struct luaL_Reg csv_methods[] = {
    {"parse_file",   l_parse_file},
    {"parse_string", l_parse_string},
    {NULL, NULL}
};

/* 模块入口 */
#if defined(_WIN32)
__declspec(dllexport)
#endif
int luaopen_csv_core(lua_State *L) {
#if LUA_VERSION_NUM >= 502
    luaL_newlib(L, csv_methods);
#else
    luaL_register(L, "csv.core", csv_methods);
#endif
    return 1;
}