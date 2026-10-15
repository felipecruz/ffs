# Internal commands: how agents search code

What the agents run by aiflow (mostly Codex, some Claude Code) actually do when they search this
repository. Source: the 141 per-job logs in `.aiflow/logs/` (snapshot 2026-10-15), parsed from their
`→ exec:` (Codex) and `→ Bash:` (Claude Code) lines. 97 of the 3,614 shell commands could not be
parsed (truncated quoting) and are excluded.

## Headline numbers

| Measure | Value |
| --- | --- |
| Shell commands logged | 3,614 |
| `rg` invocations | 1,293 (Codex 1,279) |
| `grep` invocations | 218 (Claude Code 152) |
| Claude Code's built-in `Grep` / `Glob` tool calls | 24 / 11 (plus 108 `Read`) |
| Jobs that searched at all | 136 of 141 |
| Searches per job | median 9, max 54 |
| Other commands that usually go with a search | `git` 1,860, `cat` 1,332, `sed` 1,107, `tail` 1,025, `head` 500 |

**Who searches how:** Codex uses `rg` almost exclusively. Claude Code, run headless through `-p`,
mostly shells out to `grep` and uses its own `Grep`/`Glob` tools only now and then. Both agents
search, then read: in 182 commands an `rg -n` is chained straight into `sed -n 'X,Yp'` to read the
lines around a match.

## The five main use cases

### 1. Orienting on the repo at job start (`rg --files` inventory) — 254 calls, in 123 jobs

Nearly every Codex job starts by listing project files that match a set of names instead of reading
the directory tree:

```sh
rg --files -g AGENTS.md -g '*README*' -g DEV.md -g ROADMAP.md -g Package.swift -g Makefile -g '*.sh'
rg --files --hidden -g '*instructions*' -g AGENTS.md -g CLAUDE.md
rg --files -g AGENTS.md -g '*Analytics*' -g '*analytics*' -g ROADMAP.md -g '*Test*' -g Package.swift
```

- `-g` was used 1,059 times inside these listings. The most common globs: `AGENTS.md` (176),
  `Package.swift` (102), `ROADMAP.md` (89), `README*` (76), `Makefile` (51), and test globs `*Tests*`,
  `*Test*`, `*test*` (83 together).
- **Two kinds of globs.** Fixed ones look for agent instructions and the build setup (`AGENTS.md`,
  `CLAUDE.md`, `*instructions*`, `Package.swift`, `Makefile`, `*.xcodeproj`). Task-specific ones are
  guessed from the request (`*Analytics*`, `*Question*`, `*Job*`, `*Autopilot*`, `*F183*`).
- `--hidden` (38 times) is added so `.claude/`, `.codex/`, `.agents/` are included. Exclusions such as
  `-g '!.git'`, `-g '!build'`, `-g '!.build'`, `-g '!node_modules'` keep generated folders out.
- The agent instructions are looked for again in every job: `AGENTS.md` appears in about 85% of all
  inventories, even though the repo uses `CLAUDE.md`/`DEV.md`.

### 2. Finding code symbols — about 60% of content searches

`rg -n` (910 uses) with a set of alternatives to try, scoped to `Sources/` or to one or two named files:

```sh
rg -n 'func cancel|killGrace|cleanup|func launch' Sources/MarkdownPreview/AgentSessionLauncher.swift
rg -n 'class OwnedAgent|struct OwnedAgent|class JobStore|struct JobRecord' Sources
rg -n 'executionKey|requestedFeatures|featureID' Sources/MarkdownPreview/{AppDelegate,JobHistory,ListItem}.swift
rg -n 'autoPilot|AutoPilot'          # spelling variants instead of -i
```

- **Alternation is the main pattern style:** 857 of 1,150 content searches use `a|b|c`, averaging
  3.5 terms and up to 13. The agent guesses several possible names at once instead of running one
  query per name.
- **Declaration prefixes:** 206 patterns anchor on `func`, `struct`, `class`, `enum`, `var`, `let`,
  `static`, or `case` to jump to a definition rather than its uses (`'struct InspectorMetricTile'`,
  `'func installTestWorkspace'`).
- **Case variants are spelled out:** `-i` appears in only about 37 searches. `queue|Queue` and
  `autopilot|Autopilot` are more common.
- **Searches are tightly scoped.** Paths searched: `Sources` 579, `Tests` 218, `ROADMAP.md` 141,
  `README.md` 50, `docs` 39, `DEV.md` 25. Only 22 searches ran on the whole working directory with
  no path. Brace lists of files (`{AppDelegate,WorkspaceView}.swift`) are common.
- **Context flags** `-A`/`-B`/`-C` (53 uses, median 8 lines, max 85) are for reading a whole function
  body in one step (`rg -n -A85 'testSentNotesContext' Tests/...`).
- Patterns are short: median 26 characters, max 154. Of the content searches, 408 of 1,150 use regex
  metacharacters (`\(`, `^`, `.*`, `[0-9]+`); the rest are plain identifiers.

### 3. Navigating the roadmap (item IDs and headings) — about 120 searches

`ROADMAP.md` is treated as a structured database:

```sh
rg -o '\*\*F[0-9]+' ROADMAP.md | sort -V | tail -5   # find the next free F-number
rg -n 'F[0-9]+ —' ROADMAP.md                         # list all items
rg -n '^##' ROADMAP.md                               # version / section outline
rg -n -A13 '\*\*F239 ' ROADMAP.md                    # read one item's full block
rg -n 'F114|F117|F118|F119|F120' ROADMAP.md          # related items
rg '^- \[[ x]\] \*\*F' ROADMAP.md                    # checkbox status
```

- `-o` (31 uses) shows up almost only here, to pull out IDs before `sort -V | tail` to get the
  highest number.
- `grep -c 'Job time' ROADMAP.md` and `git show … | grep -c F218` count entries or check that an
  edit landed.

### 4. Reading build and test results — 179 searches plus most pipe filters

The single most common pattern is `error:|failed` (39). Variants with `Executed`, `warning:`,
`Fatal`, `skipped`, or `SESSION|BENCH` make up most of the top 20 patterns.

```sh
swift test 2>&1 | tee /tmp/aiflow-f236-full.log | tail -40
rg -n 'error:|failed|Executed .* tests' /tmp/aiflow-f236-full.log
rg 'Executed 13 tests|QuestionsTests.*passed' /tmp/aiflow-panels-tests.log
swift build 2>&1 | grep -E 'error:|warning:'
```

- **Write to a log, then search it:** 455 redirects to `/tmp/*.log` files, and 180 later searches on
  `/tmp/…` paths. The agent runs the long test suite once and greps the saved log as many times as it
  needs instead of rerunning.
- Assertion failures are found with `XCTAssert` and `Test Case.*failed`; pass/fail counts with
  `Executed [0-9]+ tests?, with`.

### 5. Filters inside pipelines — 107 calls

| Feeds the filter | Count | Typical use |
| --- | --- | --- |
| `cmd 2>&1 \|` | 25 | build/test output → `grep -E 'error\|Executed'` |
| `git` | 22 | `git diff \| rg '^[-+]'`, `git log \| rg F202`, `git show \| grep -c` |
| `rg` / `grep` | 42 | narrowing: `rg … \| grep -v '^Sources/.../Resources'` (`-v`, 17 uses) |
| `ps` | 12 | check for leftover test processes: `ps … \| rg 'swift-test\|xctest'` |

Output is almost always trimmed: `| head` 252, `| tail` 130, `| sort` 30, `| cut` 30.

## Flag cheat sheet (from actual use)

| `rg` flag | Uses | Meaning here |
| --- | --- | --- |
| `-n` | 910 | line numbers, so the next step can `sed -n 'X,Yp'` |
| `--files` | 254 | list files, no content search |
| `-g` / `--glob` | 205* | include/exclude by name (*outside inventories; 1,059 inside them) |
| `--hidden` | 38 | include dot-folders (`.claude`, `.codex`, `.agents`) |
| `-o` | 31 | only the match (ID extraction) |
| `-A/-B/-C N` | 53 | context lines, median 8 |
| `-i` | 15 | rare, case variants usually spelled out |
| `-l` | 2 | rare, file lists come from `--files` instead |

| `grep` flag | Uses | Meaning here |
| --- | --- | --- |
| `-n` | 104 | line numbers |
| `-rn` / `-rln` / `-rni` | 46 | recursive search (`rg` searches recursively by default) |
| `-E` | ~35 | needed for `a\|b` alternation (otherwise written `a\|b`) |
| `-i` | 27 | used more than in `rg` |
| `-v` | 17 | drop matches inside pipelines |
| `--include=*.swift` | 6 | grep's version of `-g` |

## Insights

1. **Searching is the agents' main way of finding their way around.** One in three shell
   commands (1,190 of 3,614) includes `rg`/`grep`, and 58% if you count the `sed`/`head`/`tail`/`cat`
   that read the results.
   Faster search or a code index would cut job time most directly.
2. **The inventory step is the same every job.** About 123 jobs rediscovered `AGENTS.md`,
   `Package.swift`, `Makefile`, and test folders. A short file map in the prompt (where sources,
   tests, docs, and instructions live) could replace most of the 254 `rg --files` calls.
3. **`AGENTS.md` is looked for but doesn't exist.** Codex searches for it 176 times. Adding a stub
   that points to `CLAUDE.md`/`DEV.md` would end the repeated lookup.
4. **The agents guess names.** Long alternations (`ownedFiles|ownedFolders|routeRequest|…`) and 21
   `No such file or directory` errors from `rg` on files that don't exist show the agent working from
   guessed names. A list of symbols in the prompt would help.
5. **Roadmap IDs work like primary keys.** `**F###` and `^##` searches serve to allocate IDs, look
   items up, and check status. A small `aiflow` helper (next free ID, show item, list a version)
   would replace about 120 regex calls.
6. **Test logs are written once and searched many times.** Agents save test output to `/tmp/*.log`
   and search it again and again. That files are left in `/tmp` and that orphaned `xctest`
   processes are checked with `ps | rg` both suggest a dedicated `scripts/test-summary` (failures +
   counts) would be worth adding.
7. **Claude Code underuses its `Grep` tool.** In headless `-p` mode it runs shell `grep -rn` instead
   (152 vs 24). The logs record both the same way (`→ Bash: grep …` vs `→ Grep: <pattern>`), but the
   shell version gets none of the built-in tool's path filtering or result limits.

## Reproducing these numbers

```sh
# every shell command that searched
rg -n '^→ (exec|Bash): .*\b(rg|grep)\b' .aiflow/logs
# just the search calls, split out of chained commands
rg -o '\b(rg|grep) [^;|&]*' .aiflow/logs --no-filename | sort | uniq -c | sort -rn | head -40
# most common -g globs
rg -o "\-g '?[^ ']+" .aiflow/logs --no-filename | sort | uniq -c | sort -rn | head -20
# Claude Code's built-in search tools
rg '^→ (Grep|Glob): ' .aiflow/logs
```

Note: logs keep only summarized output (tool results are cut to 500 characters) and old logs are
pruned, so these are lower bounds for long-running projects.