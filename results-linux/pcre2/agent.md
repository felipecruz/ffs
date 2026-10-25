| # | What the agent wants | Call | ffs | ripgrep | |
|---:|:---|:---|---:|---:|:---|
| 1 | Find the build files and docs | `rg --files -g '*README*' -g Makefile -g '*.sh' -g AGENTS.md` | **3.6 ms** | 6.4 ms | 1.8x faster |
| 2 | Look for agent instructions | `rg --files --hidden -g '*instructions*' -g CLAUDE.md -g AGENTS.md` | **3.6 ms** | 6.4 ms | 1.8x faster |
| 3 | Guess a symbol's name | `rg -n 'dictFind\|dictAdd\|dictDelete' src` | **4.4 ms** | 6.9 ms | 1.6x faster |
| 4 | Jump to a declaration | `rg -n 'struct redisServer \{\|struct client \{' src/server.h` | **1.2 ms** | 2.1 ms | 1.8x faster |
| 5 | Read a function body | `rg -n -A40 '^dictEntry \*dictFind\(' src/dict.c` | **1.1 ms** | 2.0 ms | 1.9x faster |
| 6 | Spell out case variants | `rg -n 'lazyfree\|lazyFree\|LazyFree' src` | **4.4 ms** | 6.9 ms | 1.6x faster |
| 7 | Search the whole repo | `rg -n serverAssert` | **4.9 ms** | 8.2 ms | 1.7x faster |
| 8 | Count uses per file | `rg -c 'serverLog\(LL_WARNING' src` | **4.2 ms** | 6.8 ms | 1.6x faster |
| 9 | Which files call it | `rg -l aeCreateFileEvent src` | **4.2 ms** | 6.7 ms | 1.6x faster |
| 10 | Whole word only | `rg -w -n dictSize src` | **4.3 ms** | 6.9 ms | 1.6x faster |
| 11 | Pull out IDs | `rg -o -n 'REDIS_VERSION "[0-9.]+"\|RDB_VERSION [0-9]+' src` | **4.4 ms** | 7.0 ms | 1.6x faster |
| 12 | Tests that mention it | `rg -n -g '*.tcl' 'lazyfree' tests` | **3.7 ms** | 5.1 ms | 1.4x faster |
| 13 | Read a saved test log | `rg -n 'err\]\|exception\]\|Executed [0-9]+ tests'` | **2.8 ms** | 3.5 ms | 1.2x faster |
| 14 | Regex with no literal | `rg -n '[0-9a-f]{16}' src` | **4.4 ms** | 7.2 ms | 1.6x faster |
| 15 | Alternation with a common word | `rg -n 'dictFind\|struct [a-z]+ \{' src` | **4.5 ms** | 7.2 ms | 1.6x faster |

The whole session: ffs 55.6 ms, ripgrep 89.4 ms.
