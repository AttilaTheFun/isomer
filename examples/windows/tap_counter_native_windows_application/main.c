// The NATIVE Windows baseline of the cross-framework counter benchmark
// (docs/benchmarks.md#windows): a hand-written Win32 app — one STATIC label +
// one owner-drawn BUTTON, visually matched to the shared TapCounter.swift spec
// (#5A57D6 fill, 10px rounded corners, white semibold 17px "Tap me", gray 20px
// counter label, 24px gap) — with NO Swift, no Isomer, no framework. The
// Win32 peer of the Android benchmark's hand-written native-Views cell: the
// floor for what the platform's own widget system costs.
//
// Bench mode (ISO_BENCH=1, stderr):
//   [iso-content-frame] <epoch_ms>   after the first paint that shows content
//   [iso-tap] <ms>                   per tap: BM_CLICK dispatch -> label repainted
//   [iso-tap-summary] med=<ms> mean=<ms>
// then exits, so a driver can loop cold starts. Without the env it's a normal
// interactive app.

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>

#define IDC_BUTTON 101
#define IDC_LABEL 102
#define BENCH_TAPS 15

static HWND g_label;
static HWND g_button;
static HFONT g_label_font;
static HFONT g_button_font;
static int g_count;
static int g_first_paint_logged;

static double epoch_ms(void) {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    // FILETIME epoch (1601) -> Unix epoch (1970), 100ns ticks -> ms.
    return (double)(u.QuadPart - 116444736000000000ULL) / 10000.0;
}

static void update_label(void) {
    char text[64];
    snprintf(text, sizeof(text), "Tapped %d time%s", g_count, g_count == 1 ? "" : "s");
    SetWindowTextA(g_label, text);
}

static void layout(HWND hwnd) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    int cx = (rc.right - rc.left) / 2;
    int cy = (rc.bottom - rc.top) / 2;
    // Label (20px) above, button below, 24px gap — centered like the VStack.
    int label_w = 360, label_h = 28;
    int button_w = 150, button_h = 47;  // text 17px + pad h28 v12
    int total = label_h + 24 + button_h;
    MoveWindow(g_label, cx - label_w / 2, cy - total / 2, label_w, label_h, TRUE);
    MoveWindow(g_button, cx - button_w / 2, cy - total / 2 + label_h + 24, button_w, button_h, TRUE);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_COMMAND:
        if (LOWORD(wp) == IDC_BUTTON) {
            g_count++;
            update_label();
            // Synchronous repaint so a caller timing BM_CLICK -> return sees
            // the presented frame (GDI paints are synchronous on completion).
            UpdateWindow(g_label);
            return 0;
        }
        break;
    case WM_CTLCOLORSTATIC:
        if ((HWND)lp == g_label) {
            HDC dc = (HDC)wp;
            SetTextColor(dc, RGB(128, 128, 128));
            SetBkColor(dc, RGB(255, 255, 255));
            return (LRESULT)GetStockObject(WHITE_BRUSH);
        }
        break;
    case WM_DRAWITEM:
        if (wp == IDC_BUTTON) {
            const DRAWITEMSTRUCT *dis = (const DRAWITEMSTRUCT *)lp;
            HDC dc = dis->hDC;
            RECT rc = dis->rcItem;
            // #5A57D6 (0.35, 0.34, 0.84), 10px rounded corners; slightly darker
            // while pressed, matching the ISO press feedback.
            int pressed = (dis->itemState & ODS_SELECTED) != 0;
            COLORREF fill = pressed ? RGB(74, 71, 178) : RGB(90, 87, 214);
            HBRUSH brush = CreateSolidBrush(fill);
            HPEN pen = CreatePen(PS_SOLID, 1, fill);
            HGDIOBJ old_brush = SelectObject(dc, brush);
            HGDIOBJ old_pen = SelectObject(dc, pen);
            RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom, 20, 20);
            SetTextColor(dc, RGB(255, 255, 255));
            SetBkMode(dc, TRANSPARENT);
            HGDIOBJ old_font = SelectObject(dc, g_button_font);
            DrawTextA(dc, "Tap me", -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            SelectObject(dc, old_font);
            SelectObject(dc, old_pen);
            SelectObject(dc, old_brush);
            DeleteObject(pen);
            DeleteObject(brush);
            return TRUE;
        }
        break;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        FillRect(dc, &ps.rcPaint, (HBRUSH)GetStockObject(WHITE_BRUSH));
        EndPaint(hwnd, &ps);
        if (!g_first_paint_logged) {
            g_first_paint_logged = 1;
            fprintf(stderr, "[iso-content-frame] %.3f\n", epoch_ms());
            fflush(stderr);
        }
        return 0;
    }
    case WM_SIZE:
        layout(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

int main(void) {
    HINSTANCE inst = GetModuleHandleA(NULL);
    SetProcessDPIAware();

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    wc.lpszClassName = "TapCounterNative";
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowA(
        "TapCounterNative", "Tap Counter (native)", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 1100, 720, NULL, NULL, inst, NULL);

    // Segoe UI: 20px regular for the label, 17px semibold for the button.
    g_label_font = CreateFontA(
        -20, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, "Segoe UI");
    g_button_font = CreateFontA(
        -17, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, "Segoe UI");

    g_label = CreateWindowA(
        "STATIC", "Tapped 0 times", WS_CHILD | WS_VISIBLE | SS_CENTER,
        0, 0, 0, 0, hwnd, (HMENU)IDC_LABEL, inst, NULL);
    SendMessageA(g_label, WM_SETFONT, (WPARAM)g_label_font, TRUE);

    g_button = CreateWindowA(
        "BUTTON", "Tap me", WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
        0, 0, 0, 0, hwnd, (HMENU)IDC_BUTTON, inst, NULL);
    SendMessageA(g_button, WM_SETFONT, (WPARAM)g_button_font, TRUE);

    layout(hwnd);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    const char *bench = getenv("ISO_BENCH");
    int bench_taps_left = (bench && bench[0] == '1') ? BENCH_TAPS : 0;
    double taps[BENCH_TAPS];
    int taps_done = 0;
    ULONGLONG next_tap_at = GetTickCount64() + 500;  // settle before tapping

    MSG msg;
    for (;;) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) return 0;
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        if (bench_taps_left > 0 && GetTickCount64() >= next_tap_at) {
            // BM_CLICK synthesizes WM_LBUTTONDOWN/UP through the button's own
            // wndproc; SendMessage returns after WM_COMMAND ran (count bumped,
            // label repainted synchronously) — the same present a real click
            // produces, minus only the hardware input hop.
            double t0 = epoch_ms();
            SendMessageA(g_button, BM_CLICK, 0, 0);
            double dt = epoch_ms() - t0;
            taps[taps_done++] = dt;
            fprintf(stderr, "[iso-tap] %.3f\n", dt);
            fflush(stderr);
            bench_taps_left--;
            next_tap_at = GetTickCount64() + 150;
            if (bench_taps_left == 0) {
                qsort(taps, taps_done, sizeof(double), compare_double);
                double sum = 0;
                for (int i = 0; i < taps_done; i++) sum += taps[i];
                fprintf(stderr, "[iso-tap-summary] med=%.3f mean=%.3f n=%d\n",
                        taps[taps_done / 2], sum / taps_done, taps_done);
                fflush(stderr);
                PostQuitMessage(0);
            }
        }
        // Idle politely: wait for input or the next scheduled bench tap.
        MsgWaitForMultipleObjects(0, NULL, FALSE, bench_taps_left ? 16 : 100, QS_ALLINPUT);
    }
}
