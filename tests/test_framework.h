#ifndef TEST_FRAMEWORK_H
#define TEST_FRAMEWORK_H

#include <math.h>
#include <stdio.h>

static int g_pass = 0;
static int g_fail = 0;

#define ASSERT_TRUE(expr) \
    do { \
        if (expr) { \
            printf("  [PASS] %s\n", #expr); \
            g_pass++; \
        } else { \
            printf("  [FAIL] %s  (line %d)\n", #expr, __LINE__); \
            g_fail++; \
        } \
    } while (0)

#define ASSERT_NEAR(a, b, tol) \
    do { \
        float _a = (float)(a); \
        float _b = (float)(b); \
        float _t = (float)(tol); \
        if (fabsf(_a - _b) <= _t) { \
            printf("  [PASS] |%s - %s| <= " #tol "\n", #a, #b); \
            g_pass++; \
        } else { \
            printf("  [FAIL] |%s - %s| <= " #tol "  (%.7g vs %.7g, diff=%.3e, line %d)\n", \
                   #a, #b, _a, _b, fabsf(_a - _b), __LINE__); \
            g_fail++; \
        } \
    } while (0)

#define RUN_TEST(fn) \
    do { printf("\n[ %s ]\n", #fn); fn(); } while (0)

#define PRINT_RESULTS() \
    do { \
        printf("\n========================================\n"); \
        printf("Results: %d passed, %d failed\n", g_pass, g_fail); \
        printf("========================================\n"); \
    } while (0)

#endif /* TEST_FRAMEWORK_H */
