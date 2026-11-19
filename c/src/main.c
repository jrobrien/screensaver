/* Sakura & Bamboo terminal screensaver.
 *
 *   saver                          run full screen in this terminal; any key quits
 *   saver --live 6 --burn 6        shorter cycle
 *   saver --still out.ppm --phase burn --at 4   headless still frame
 */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "palettes.h"
#include "render.h"
#include "show.h"
#include "still.h"

#define ENTER "\x1b[?1049h\x1b[?25l\x1b[?7l"   /* alt screen, hide cursor, no autowrap */
#define LEAVE "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l"

static volatile sig_atomic_t g_resized = 1;
static volatile sig_atomic_t g_quit = 0;

static void on_winch(int sig)
{
    (void)sig;
    g_resized = 1;
}

static void on_quit(int sig)
{
    (void)sig;
    g_quit = 1;
}

typedef struct {
    int fps;
    double live, burn, max_seconds, at;
    int palette;   /* -1 rotate */
    const char *still;
    Phase phase;
    int cols, rows;
    uint64_t seed;
    int have_seed;
} Options;

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int write_all(int fd, const char *p, size_t n)
{
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN) {
                struct pollfd pf = {fd, POLLOUT, 0};
                poll(&pf, 1, 100);
                continue;
            }
            return -1;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static void term_size(int *cols, int *rows)
{
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
        *cols = ws.ws_col;
        *rows = ws.ws_row;
    } else {
        *cols = 80;
        *rows = 24;
    }
}

static int run_terminal(const Options *o)
{
    struct termios saved, raw;
    if (tcgetattr(STDIN_FILENO, &saved) != 0) {
        fprintf(stderr, "saver: stdin is not a terminal\n");
        return 1;
    }
    raw = saved;
    raw.c_lflag &= (tcflag_t) ~(ICANON | ECHO);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);
    sa.sa_handler = on_quit;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    Show *show = NULL;
    Cells *cells = NULL;
    Emitter em;
    emitter_init(&em);
    int status = 0;
    uint64_t seed = o->have_seed ? o->seed : (uint64_t)time(NULL) ^ ((uint64_t)now_s() << 20);
    const double frame_t = 1.0 / o->fps;

    tcsetattr(STDIN_FILENO, TCSADRAIN, &raw);
    write_all(STDOUT_FILENO, ENTER, strlen(ENTER));
    double start = now_s(), last = start;
    while (!g_quit) {
        if (g_resized) {
            g_resized = 0;
            int cols, rows;
            term_size(&cols, &rows);
            Cells *nc = cells_new(cols, rows);
            if (!nc) { status = 1; break; }
            cells_free(cells);
            cells = nc;
            if (!show)
                show = show_new(cols, rows * 2, o->live, o->burn, o->palette, seed);
            else if (show_resize(show, cols, rows * 2))
                { status = 1; break; }
            if (!show) { status = 1; break; }
            emitter_reset(&em);
        }
        double now = now_s();
        double dt = now - last;
        last = now;
        if (dt > 0.1) dt = 0.1;
        if (show_step(show, dt)) { status = 1; break; }
        to_cells(cells, show->img, show->mask);
        const char *buf;
        size_t n;
        if (emitter_frame(&em, cells, &buf, &n) || write_all(STDOUT_FILENO, buf, n)) {
            status = 1;
            break;
        }
        if (o->max_seconds > 0 && now - start > o->max_seconds)
            break;
        double wait = frame_t - (now_s() - now);
        int ms = wait > 0 ? (int)(wait * 1000 + 0.999) : 0;
        struct pollfd pf = {STDIN_FILENO, POLLIN, 0};
        int rc = poll(&pf, 1, ms);
        if (rc > 0 && (pf.revents & (POLLIN | POLLHUP | POLLERR))) {   /* any key quits */
            char b[64];
            if (read(STDIN_FILENO, b, sizeof b) >= 0 || errno != EINTR)
                break;                  /* a key, EOF or a real error: stop */
        }
    }
    write_all(STDOUT_FILENO, LEAVE, strlen(LEAVE));
    tcsetattr(STDIN_FILENO, TCSADRAIN, &saved);
    emitter_fini(&em);
    cells_free(cells);
    show_free(show);
    if (status)
        fprintf(stderr, "saver: out of memory or write error\n");
    return status;
}

static int run_still(const Options *o)
{
    Show *show = show_new(o->cols, o->rows * 2, o->live, o->burn, o->palette, 1);
    Cells *cells = cells_new(o->cols, o->rows);
    int rc = 1;
    if (show && cells) {
        show_seek(show, o->phase, o->at);
        to_cells(cells, show->img, show->mask);
        rc = still_write_ppm(cells, o->still) ? 1 : 0;
        if (rc)
            fprintf(stderr, "saver: cannot write %s\n", o->still);
    } else {
        fprintf(stderr, "saver: out of memory\n");
    }
    cells_free(cells);
    show_free(show);
    return rc;
}

static void usage(FILE *f)
{
    fputs("usage: saver [--fps N] [--live S] [--burn S] [--palette ember|moon|dusk]\n"
          "             [--max-seconds S] [--seed N]\n"
          "             [--still FILE.ppm [--phase grow|live|burn] [--at S] [--size COLSxROWS]]\n",
          f);
}

/* Accepts "--flag value" and "--flag=value". Returns the value or NULL. */
static const char *optval(int argc, char **argv, int *i, const char *name)
{
    size_t n = strlen(name);
    if (strncmp(argv[*i], name, n) != 0)
        return NULL;
    if (argv[*i][n] == '=')
        return argv[*i] + n + 1;
    if (argv[*i][n] == '\0' && *i + 1 < argc)
        return argv[++*i];
    return NULL;
}

/* Whole-string numbers: 0 on success, -1 if v is not entirely a number. */
static int to_num(const char *v, double *out)
{
    char *end;
    errno = 0;
    *out = strtod(v, &end);
    return (end == v || *end || errno) ? -1 : 0;
}

static int to_int(const char *v, long lo, long hi, int *out)
{
    char *end;
    errno = 0;
    long n = strtol(v, &end, 10);
    if (end == v || *end || errno || n < lo || n > hi)
        return -1;
    *out = (int)n;
    return 0;
}

static int parse(int argc, char **argv, Options *o)
{
    *o = (Options){24, 24, 9, 0, 5, -1, NULL, PH_LIVE, 200, 56, 0, 0};
    for (int i = 1; i < argc; i++) {
        const char *v;
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(stdout);
            exit(0);
        } else if ((v = optval(argc, argv, &i, "--fps"))) {
            if (to_int(v, 1, 1000000, &o->fps)) return -1;
        } else if ((v = optval(argc, argv, &i, "--live"))) {
            if (to_num(v, &o->live) || o->live < 0) return -1;
        } else if ((v = optval(argc, argv, &i, "--burn"))) {
            if (to_num(v, &o->burn) || o->burn <= 0) return -1;
        } else if ((v = optval(argc, argv, &i, "--palette"))) {
            o->palette = palette_find(v);
            if (o->palette < 0) return -1;
        } else if ((v = optval(argc, argv, &i, "--max-seconds"))) {
            if (to_num(v, &o->max_seconds) || o->max_seconds < 0) return -1;
        } else if ((v = optval(argc, argv, &i, "--still"))) {
            o->still = v;
        } else if ((v = optval(argc, argv, &i, "--phase"))) {
            if (!strcmp(v, "grow")) o->phase = PH_GROW;
            else if (!strcmp(v, "live")) o->phase = PH_LIVE;
            else if (!strcmp(v, "burn")) o->phase = PH_BURN;
            else return -1;
        } else if ((v = optval(argc, argv, &i, "--at"))) {
            if (to_num(v, &o->at) || o->at < 0) return -1;
        } else if ((v = optval(argc, argv, &i, "--size"))) {
            if (sscanf(v, "%dx%d", &o->cols, &o->rows) != 2 || o->cols < 1 || o->rows < 1 ||
                o->cols > 2000 || o->rows > 1000)
                return -1;
        } else if ((v = optval(argc, argv, &i, "--seed"))) {
            o->seed = strtoull(v, NULL, 10);
            o->have_seed = 1;
        } else {
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    Options o;
    if (parse(argc, argv, &o)) {
        usage(stderr);
        return 2;
    }
    return o.still ? run_still(&o) : run_terminal(&o);
}
