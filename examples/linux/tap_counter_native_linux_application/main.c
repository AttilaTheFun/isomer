// The NATIVE Linux baseline of the cross-framework counter benchmark
// (docs/benchmarks.md#linux): a hand-written GTK3 app — one GtkLabel + one
// CSS-styled GtkButton, visually matched to the shared TapCounter.swift spec
// (#5A57D6 fill, 10px rounded corners, white semibold 17px "Tap me", gray 20px
// counter label, 24px gap) — with NO Swift, no Isomer, no framework.
// GTK is the de-facto native widget toolkit on desktop Linux, so this is the
// peer of the Win32 baseline / Android's hand-written native-Views cell.
//
// Bench mode (ISO_BENCH=1, stderr):
//   [iso-content-frame] <epoch_ms>   after the first frame that draws content
//   [iso-tap] <ms>                   per tap: clicked() dispatch -> after-paint
//   [iso-tap-summary] med=<ms> mean=<ms>
// then exits. Without the env it's a normal interactive app.
//
// Links the system GTK3 via pkg-config paths in the BUILD (a benchmark-only
// target, tagged manual — the hermetic build never pulls it in).

#include <gtk/gtk.h>

#include <stdio.h>
#include <stdlib.h>

#define BENCH_TAPS 15

static GtkWidget *g_label;
static GtkWidget *g_button;
static int g_count;
static int g_content_logged;

static double g_taps[BENCH_TAPS];
static int g_taps_done;
static double g_tap_t0;

static double epoch_ms(void) { return (double)g_get_real_time() / 1000.0; }

static void update_label(void) {
    char text[64];
    snprintf(text, sizeof(text), "Tapped %d time%s", g_count, g_count == 1 ? "" : "s");
    gtk_label_set_text(GTK_LABEL(g_label), text);
}

static void on_clicked(GtkButton *button, gpointer user_data) {
    (void)button;
    (void)user_data;
    g_count++;
    update_label();
}

static int compare_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static gboolean bench_next_tap(gpointer user_data);

/// One-shot frame-clock hook: the first paint AFTER the tap's label update is
/// the frame that presents the new value.
static void on_after_paint(GdkFrameClock *clock, gpointer user_data) {
    (void)user_data;
    double dt = epoch_ms() - g_tap_t0;
    g_signal_handlers_disconnect_by_func(clock, (gpointer)on_after_paint, NULL);
    g_taps[g_taps_done++] = dt;
    fprintf(stderr, "[iso-tap] %.3f\n", dt);
    fflush(stderr);
    if (g_taps_done >= BENCH_TAPS) {
        qsort(g_taps, g_taps_done, sizeof(double), compare_double);
        double sum = 0;
        for (int i = 0; i < g_taps_done; i++) sum += g_taps[i];
        fprintf(stderr, "[iso-tap-summary] med=%.3f mean=%.3f n=%d\n",
                g_taps[g_taps_done / 2], sum / g_taps_done, g_taps_done);
        fflush(stderr);
        gtk_main_quit();
    } else {
        g_timeout_add(150, bench_next_tap, NULL);
    }
}

static gboolean bench_next_tap(gpointer user_data) {
    (void)user_data;
    GdkFrameClock *clock = gtk_widget_get_frame_clock(g_button);
    g_tap_t0 = epoch_ms();
    // Dispatch through the button's own action signal (the same handler a real
    // pointer click runs), then time to the frame that presents the new label.
    gtk_button_clicked(GTK_BUTTON(g_button));
    g_signal_connect(clock, "after-paint", G_CALLBACK(on_after_paint), NULL);
    gdk_frame_clock_request_phase(clock, GDK_FRAME_CLOCK_PHASE_AFTER_PAINT);
    return G_SOURCE_REMOVE;
}

/// First draw of the button = the first frame with actual content on screen.
static gboolean on_button_draw(GtkWidget *widget, cairo_t *cr, gpointer user_data) {
    (void)widget;
    (void)cr;
    (void)user_data;
    if (!g_content_logged) {
        g_content_logged = 1;
        fprintf(stderr, "[iso-content-frame] %.3f\n", epoch_ms());
        fflush(stderr);
        const char *bench = getenv("ISO_BENCH");
        if (bench && bench[0] == '1') {
            g_timeout_add(500, bench_next_tap, NULL);  // settle before tapping
        }
    }
    return FALSE;  // propagate: GTK still draws the button
}

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "Tap Counter (native)");
    gtk_window_set_default_size(GTK_WINDOW(window), 1100, 720);
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    // Style: match the shared TapCounter.swift spec.
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(
        css,
        "window { background: white; }"
        "label.counter { color: #808080; font-size: 20px; }"
        "button.tap {"
        "  background-image: none; background-color: #5A57D6;"
        "  border-radius: 10px; border: none; box-shadow: none;"
        "  padding: 12px 28px; color: white;"
        "  font-size: 17px; font-weight: 600;"
        "}"
        "button.tap:active { background-color: #4A47B2; }",
        -1, NULL);
    gtk_style_context_add_provider_for_screen(
        gdk_screen_get_default(), GTK_STYLE_PROVIDER(css),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 24);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);

    g_label = gtk_label_new("Tapped 0 times");
    gtk_style_context_add_class(gtk_widget_get_style_context(g_label), "counter");

    g_button = gtk_button_new_with_label("Tap me");
    gtk_style_context_add_class(gtk_widget_get_style_context(g_button), "tap");
    g_signal_connect(g_button, "clicked", G_CALLBACK(on_clicked), NULL);
    g_signal_connect(g_button, "draw", G_CALLBACK(on_button_draw), NULL);

    gtk_box_pack_start(GTK_BOX(box), g_label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), g_button, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(window), box);

    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}
