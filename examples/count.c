/* Counts matching lines with libffs and prints the first few.
 * Usage: count [-i] [-E] <folder> <term>
 * Build and run: zig build c-example -- fixtures/redis dictFind */
#include <stdio.h>
#include <string.h>

#include "ffs.h"

struct counter {
    size_t lines;
};

static int on_match(void *ctx, const ffs_match *m) {
    struct counter *c = ctx;
    if (c->lines < 3) printf("%s:%zu:%s\n", m->path, m->line, m->text);
    c->lines++;
    return 0; /* keep going */
}

int main(int argc, char **argv) {
    unsigned flags = 0;
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (strcmp(argv[i], "-i") == 0) flags |= FFS_IGNORE_CASE;
        else if (strcmp(argv[i], "-E") == 0) flags |= FFS_REGEX;
        else break;
    }
    if (argc - i != 2) {
        fprintf(stderr, "usage: count [-i] [-E] <folder> <term>\n");
        return 2;
    }

    struct counter c = {0};
    int rc = ffs_search(argv[i], argv[i + 1], flags, 0, on_match, &c);
    if (rc < 0) {
        fprintf(stderr, "ffs_search failed: %d\n", rc);
        return 2;
    }
    printf("%zu matching lines (libffs %s)\n", c.lines, ffs_version());
    return 0;
}
