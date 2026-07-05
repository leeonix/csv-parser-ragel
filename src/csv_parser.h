#ifndef ___CSV_PARSER_H___
#define ___CSV_PARSER_H___

#include <stddef.h>
#include <stdio.h>

#if defined(__cplusplus)
extern "C" {
#endif

/* 回调函数定义：增加了 void *ctx 上下文，field_len 指向已经原地脱衣还原好的干净文本 */
typedef void (*csv_cell_cb)(void *ctx, int row_idx, int col_idx, const char *field, size_t field_len);

/* 解析器结构体：完全隐藏在实现中，暴露清洁接口 */
typedef struct csv_parser_s csv_parser_t;

/* 便捷的内存直接解析接口（最适合把整个过滤词文件读入内存后一次性解析） */
extern int csv_parse_buffer(const char *buf, size_t len, csv_cell_cb cb, void *ctx);

/* 传统的物理文件读取解析接口 */
extern int csv_parse_file(const char *filepath, csv_cell_cb cb, void *ctx);

#if defined(__cplusplus)
}
#endif
#endif // ___CSV_PARSER_H___