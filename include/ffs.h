/* ffs: recursive text search (threads + SIMD), as a C library.
 *
 * Build: `zig build` installs zig-out/lib/libffs.a and zig-out/include/ffs.h.
 * Example: examples/count.c (`zig build c-example -- <folder> <term>`).
 */
#ifndef FFS_H
#define FFS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Flags for ffs_search. */
#define FFS_IGNORE_CASE 1u /* ASCII case-insensitive */
#define FFS_REGEX 2u       /* term is a regex (syntax: src/regex.zig) */

/* Return values of ffs_search. */
#define FFS_OK 0        /* searched everything */
#define FFS_STOPPED 1   /* the callback asked to stop */
#define FFS_EARG (-1)   /* NULL argument, empty term, or term with '\n' */
#define FFS_EREGEX (-2) /* invalid regex */
#define FFS_EROOT (-3)  /* root folder can't be opened */
#define FFS_ENOMEM (-4) /* out of memory */

typedef struct ffs_match {
    const char *path; /* "<root>/<relative path>", NUL-terminated */
    size_t line;      /* 1-based line number */
    const char *text; /* the line without '\n', NUL-terminated */
    size_t text_len;
} ffs_match;

/* Called once per matching line. Never called concurrently; one file's
 * lines arrive in order and files never interleave. `m` and its strings are
 * valid only during the call. Return 0 to continue, nonzero to stop. */
typedef int (*ffs_callback)(void *ctx, const ffs_match *m);

/* Searches every text file under `root` (recursively, nothing ignored,
 * binary files skipped) for lines containing `term`. `threads` = 0 means
 * automatic: the performance-core count on Apple silicon, else every logical
 * CPU. Blocks until done. */
int ffs_search(const char *root, const char *term, unsigned flags,
               unsigned threads, ffs_callback cb, void *ctx);

/* The library version, e.g. "0.0.8". */
const char *ffs_version(void);

#ifdef __cplusplus
}
#endif

#endif
