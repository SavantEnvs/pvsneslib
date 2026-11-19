/*
 * mayhem/cli_wrapper.c - gives pvsneslib's file-converting CLIs a Mayhem-friendly front door.
 *
 * Every tool reads its input by file NAME (the extension and basename matter) and writes its outputs
 * next to the input or into the current directory. Mayhem hands us an anonymous input path, so this
 * wrapper stages the input in a private scratch directory under a fixed name, chdirs there and calls the
 * tool's real main(), built with -Dmain=tool_main. The tool code itself is unmodified.
 *
 *   <tool> [--ext=.png] [--with=/abs/path]... [--in=N] <tool args...>
 *
 *   --ext=E    the staged input is named "input<E>" (default: "input")
 *   --with=P   also stage the fixed file P (its basename) next to the input
 *   --in=N     tool argv[N] is the input (default: the last argument)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef TOOL_MAIN
#define TOOL_MAIN tool_main
#endif
extern int TOOL_MAIN(int argc, char **argv);

static char scratch[256];

/* Absent in the non-sanitized oracle build. */
extern void __sanitizer_set_death_callback(void (*)(void)) __attribute__((weak));

static int rm_cb(const char *path, const struct stat *sb, int flag, struct FTW *ftw)
{
    (void)sb; (void)flag; (void)ftw;
    return remove(path);
}

static void cleanup(void)
{
    if (scratch[0]) {
        if (chdir("/") == 0)
            nftw(scratch, rm_cb, 8, FTW_DEPTH | FTW_PHYS);
    }
}

static int copy_file(const char *src, const char *dst)
{
    char buf[65536];
    ssize_t n;
    int in = open(src, O_RDONLY);
    if (in < 0)
        return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out < 0) {
        close(in);
        return -1;
    }
    while ((n = read(in, buf, sizeof buf)) > 0) {
        if (write(out, buf, (size_t)n) != n) {
            n = -1;
            break;
        }
    }
    close(in);
    close(out);
    return n < 0 ? -1 : 0;
}

int main(int argc, char **argv)
{
    const char *ext = "";
    const char *with[8];
    int nwith = 0, in_index = -1, i = 1;
    char staged[512], dst[512];

    for (; i < argc; i++) {
        if (strncmp(argv[i], "--ext=", 6) == 0)
            ext = argv[i] + 6;
        else if (strncmp(argv[i], "--with=", 7) == 0 && nwith < 8)
            with[nwith++] = argv[i] + 7;
        else if (strncmp(argv[i], "--in=", 5) == 0)
            in_index = atoi(argv[i] + 5);
        else
            break;
    }

    int targc = 1 + (argc - i);
    char **targv = calloc((size_t)targc + 1, sizeof *targv);
    if (!targv)
        return 2;
    targv[0] = argv[0];
    for (int k = 1; k < targc; k++)
        targv[k] = argv[i + k - 1];
    if (in_index < 0)
        in_index = targc - 1;
    if (targc < 2 || in_index < 1 || in_index >= targc) {
        fprintf(stderr, "wrapper: no input argument\n");
        return 2;
    }

    const char *tmp = getenv("TMPDIR");
    snprintf(scratch, sizeof scratch, "%s/pvsl-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(scratch)) {
        perror("mkdtemp");
        scratch[0] = 0;
        return 2;
    }
    atexit(cleanup);
    /* A halting ASan/UBSan report ends the process without running atexit handlers. */
    if (__sanitizer_set_death_callback)
        __sanitizer_set_death_callback(cleanup);

    snprintf(staged, sizeof staged, "input%s", ext);
    snprintf(dst, sizeof dst, "%s/%s", scratch, staged);
    if (copy_file(targv[in_index], dst) != 0) {
        fprintf(stderr, "wrapper: cannot stage %s\n", targv[in_index]);
        return 2;
    }
    for (int k = 0; k < nwith; k++) {
        char *dup = strdup(with[k]);
        snprintf(dst, sizeof dst, "%s/%s", scratch, basename(dup));
        free(dup);
        if (copy_file(with[k], dst) != 0) {
            fprintf(stderr, "wrapper: cannot stage %s\n", with[k]);
            return 2;
        }
    }
    targv[in_index] = staged;
    if (chdir(scratch) != 0) {
        perror("chdir");
        return 2;
    }
    /* Some tools end main() without a return; once renamed, that value is garbage, so it is not used. */
    TOOL_MAIN(targc, targv);
    return 0;
}
