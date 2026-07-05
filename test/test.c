/*
 * =====================================================================================
 * Filename:  test.c
 * Description:  CSV 解析器命令行测试程序 (VS2010 / C89 Compliant)
 * Usage:  test.exe <filepath.csv>
 * =====================================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "csv_parser.h"

/* * 自定义上下文结构体：用于在回调函数中收集统计信息
 */
typedef struct {
    int total_cells;    /* 解析出的单元格总数 */
    int max_cols;       /* 单行出现过的最大列数 */
    int print_limit;    /* 限制控制台打印的行数，防刷屏 */
} parse_stats_t;

/*
 * 核心回调函数：每当 Ragel 解析出一个干净的单元格时触发
 */
static void on_csv_cell(void *ctx, int row_idx, int col_idx, const char *field, size_t field_len) {
    /* 严格按照 C89 规范，在块顶部声明变量 */
    parse_stats_t *stats = (parse_stats_t *)ctx;
    
    /* 统计单元格与列数 */
    stats->total_cells++;
    if (col_idx + 1 > stats->max_cols) {
        stats->max_cols = col_idx + 1;
    }

    /* 前 N 行详细打印，方便验证 "" 原地清洗和边界截取是否正确 */
    if (row_idx < stats->print_limit) {
        /* field 已经在底层 Buffer 中被安全加上了 '\0' 终结符，可以直接用 %s 打印 */
        printf("  [Row %4d | Col %2d] (%2u bytes): \"%s\"\n", 
               row_idx + 1, col_idx + 1, (unsigned int)field_len, field);
    } else if (row_idx == stats->print_limit && col_idx == 0) {
        printf("  ...\n  (前 %d 行展示完毕，后续几千行屏蔽词正在后台极速校验中...)\n", stats->print_limit);
    }
}

int main(int argc, char *argv[]) {
    /* 严格遵守 C89：所有局部变量必须在 main 函数第一行声明！ */
    const char *filepath;
    parse_stats_t stats;
    clock_t start_time, end_time;
    double elapsed_ms;
    int total_rows;

    /* 检查命令行参数 */
    if (argc < 2) {
        printf("==================================================\n");
        printf("【错误】缺少输入文件参数！\n");
        printf(" 用法: %s <csv文件名>\n", argv[0]);
        printf(" 示例: %s dirty_words.csv\n", argv[0]);
        printf("==================================================\n");
        return 1;
    }

    filepath = argv[1];
    
    /* 初始化统计结构体 */
    stats.total_cells = 0;
    stats.max_cols = 0;
    stats.print_limit = 10; /* 默认只在屏幕上打印前 10 行 */

    printf("==================================================\n");
    printf("开始载入并解析 CSV 文件: %s\n", filepath);
    printf("==================================================\n");

    /* 启动毫秒级计时器 */
    start_time = clock();

    /* 调用我们封装好的物理文件解析接口 */
    total_rows = csv_parse_file(filepath, on_csv_cell, &stats);

    /* 停止计时 */
    end_time = clock();
    elapsed_ms = ((double)(end_time - start_time) / CLOCKS_PER_SEC) * 1000.0;

    printf("==================================================\n");
    
    /* 异常处理 */
    if (total_rows < 0) {
        printf("【解析失败】文件无法打开，或存在严重的 CSV 语法错误！\n");
        return -1;
    }

    /* 打印最终数据报告 */
    printf("【解析成功】性能与数据报告:\n");
    printf("  - 总行数 (Rows)  : %d 行\n", total_rows);
    printf("  - 最大列数 (Cols): %d 列\n", stats.max_cols);
    printf("  - 总字段数       : %d 个单元格\n", stats.total_cells);
    printf("  - 耗时 (Time)    : %.3f 毫秒 (ms)\n", elapsed_ms);
    printf("==================================================\n");

    return 0;
}