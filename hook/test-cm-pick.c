// 单元测试：验证 CM 窗口的选择逻辑（与 sas_proxy.c 的 FindCmProc 同构）
// 构造一批模拟窗口描述，检查选择结果是否符合预期。
// 编译：cl /nologo /utf-8 /O1 test-cm-pick.c
#include <stdio.h>
#include <windows.h>

typedef struct {
    HWND best;
    int  bestArea;
} CmSearch;

typedef struct {
    HWND hwnd;
    BOOL iconic;
    int w, h;
    BOOL visible;
} MockWin;

static int g_fail = 0;

// 与 sas_proxy.c 完全一致的择优逻辑（去掉 pid/类名过滤，那部分靠实测）
static void PickOne(MockWin *wins, int n, CmSearch *s) {
    for (int i = 0; i < n; i++) {
        MockWin *m = &wins[i];

        // 最小化状态：直接视为强候选，立即确定
        if (m->iconic) {
            s->best = m->hwnd;
            s->bestArea = 0x7FFFFFFF;
            return;
        }

        // 非最小化小窗口（含 Flutter 的 1x1 辅助窗口）
        if (m->w < 50 || m->h < 50) {
            if (s->best == NULL) { s->best = m->hwnd; s->bestArea = m->w * m->h; }
            continue;
        }

        int area = m->w * m->h;
        if (area > s->bestArea) { s->best = m->hwnd; s->bestArea = area; }
    }
}

static BOOL RunCase(const char *name, MockWin *wins, int n, HWND expect) {
    CmSearch s;
    s.best = NULL;
    s.bestArea = -1;
    PickOne(wins, n, &s);
    BOOL ok = (s.best == expect);
    printf("[%s] %-52s picked=%p expect=%p  area=%d\n",
           ok ? "PASS" : "FAIL", name, (void *)s.best, (void *)expect, s.bestArea);
    if (!ok) g_fail++;
    return ok;
}

int main(void) {
    printf("=== CM window pick logic unit test ===\n\n");

    // 场景 1（实测抓到的真实情况）：CM 窗口已最小化 + Flutter 1x1 辅助窗口
    //   辅助窗口 1x1 面积=1；CM 窗口最小化 rect 160x28
    //   关键：最小化必须直接胜出，否则 160x28 会被尺寸过滤误杀
    {
        MockWin w[] = {
            { (HWND)0x111, FALSE,   1,   1, FALSE },  // 1x1 辅助窗口
            { (HWND)0x222, TRUE,  160,  28, TRUE  },  // CM 窗口（最小化）
        };
        RunCase("real case: 1x1 helper + minimized CM(160x28)", w, 2, (HWND)0x222);
    }

    // 场景 2：CM 窗口正常可见（用户主动打开 CM，300x490）
    {
        MockWin w[] = {
            { (HWND)0x111, FALSE,   1,   1, TRUE  },  // 1x1 辅助窗口
            { (HWND)0x222, FALSE, 300, 490, TRUE  },  // CM 窗口 正常尺寸
        };
        RunCase("CM visible at real size 300x490", w, 2, (HWND)0x222);
    }

    // 场景 3：只有一个 1x1 辅助窗口（CM 还没创建）
    //   期望：退而求其次选中它，不能返回 NULL 让循环空转
    {
        MockWin w[] = {
            { (HWND)0x111, FALSE,   1,   1, FALSE },
        };
        RunCase("only 1x1 helper present (CM not created yet)", w, 1, (HWND)0x111);
    }

    // 场景 4：辅助窗口排在前面，CM 窗口在后面，但 CM 更大
    {
        MockWin w[] = {
            { (HWND)0x111, FALSE,   1,   1, FALSE },
            { (HWND)0x333, FALSE, 300, 490, TRUE  },
            { (HWND)0x444, FALSE, 100, 100, TRUE  },  // 另一个较小的普通窗口
        };
        RunCase("helper first, CM later, pick largest", w, 3, (HWND)0x333);
    }

    // 场景 5：最小化窗口出现在列表靠后，前面已有正常候选
    //   期望：最小化的仍然胜出（它一定是主窗口，辅助窗口从不最小化）
    {
        MockWin w[] = {
            { (HWND)0x333, FALSE, 300, 490, TRUE  },
            { (HWND)0x222, TRUE,  160,  28, TRUE  },
        };
        RunCase("minimized CM beats earlier normal candidate", w, 2, (HWND)0x222);
    }

    // 场景 6：空列表
    {
        CmSearch s;
        s.best = NULL;
        s.bestArea = -1;
        printf("[%s] %-52s picked=(null)\n",
               s.best == NULL ? "PASS" : "FAIL", "empty window list");
        if (s.best != NULL) g_fail++;
    }

    printf("\n=== %s (%d failed) ===\n", g_fail == 0 ? "ALL PASS" : "HAS FAILURES", g_fail);
    return g_fail == 0 ? 0 : 1;
}