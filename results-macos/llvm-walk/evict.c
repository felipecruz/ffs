// evict DIR [PCT]   drop PCT% (default 100) of DIR's files from the page cache
// evict -r DIR      report how much of DIR is resident
// Eviction is msync(MS_INVALIDATE) on a mapping, as vmtouch -e does on macOS.
// Which files: a hash of the path, so the same PCT picks the same files.
#define _DARWIN_C_SOURCE
#include <fcntl.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int report = 0, pct = 100;
static unsigned long long total = 0, resident = 0, files = 0, evicted = 0;

static unsigned hash(const char *s) {
    unsigned h = 2166136261u;
    while (*s) h = (h ^ (unsigned char)*s++) * 16777619u;
    return h;
}

static int visit(const char *path, const struct stat *st, int type, struct FTW *f) {
    (void)f;
    if (type != FTW_F || !S_ISREG(st->st_mode) || st->st_size == 0) return 0;
    if (!report && (int)(hash(path) % 100) >= pct) return 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    size_t len = (size_t)st->st_size;
    void *p = mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0);
    if (p != MAP_FAILED) {
        if (report) {
            size_t pg = (size_t)getpagesize(), n = (len + pg - 1) / pg;
            char *v = malloc(n);
            if (v && mincore(p, len, v) == 0)
                for (size_t i = 0; i < n; i++) if (v[i] & 1) resident += (i + 1 < n) ? pg : len - i * pg;
            free(v);
            total += len;
        } else if (msync(p, len, MS_INVALIDATE) == 0) {
            evicted++;
        }
        munmap(p, len);
    }
    close(fd);
    files++;
    return 0;
}

int main(int argc, char **argv) {
    int i = 1;
    if (argc > 1 && strcmp(argv[1], "-r") == 0) { report = 1; i++; }
    if (i >= argc) { fprintf(stderr, "usage: evict [-r] DIR [PCT]\n"); return 2; }
    if (i + 1 < argc) pct = atoi(argv[i + 1]);
    nftw(argv[i], visit, 64, FTW_PHYS);
    if (report)
        printf("%llu files, %.0f MB, %.0f MB resident (%.0f%%)\n", files, total / 1e6,
               resident / 1e6, total ? 100.0 * resident / total : 0);
    else
        printf("evicted %llu of %llu files\n", evicted, files);
    return 0;
}
