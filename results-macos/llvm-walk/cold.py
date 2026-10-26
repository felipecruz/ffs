# cold.py OUT.json ROUNDS PCT
# Each run: evict PCT% of the LLVM tree, then one search. Commands alternate,
# order reversed every other round. Records wall time and page-ins per run.
import json, os, re, subprocess, sys, time

S = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "/Users/felipecruz/Projects/personal/ffs"
L = f"{REPO}/fixtures/llvm"
EVICT = f"{S}/tools/evict"
FFS = f"{S}/walkexp/zig-out/release/ffs"
RG = "/opt/homebrew/bin/rg"
PAT = ["-n", "-F", "-e", "isNoopIntrinsic", L]

CMDS = {
    "ffs -j4 lifo": ("lifo", [FFS, "-j4", "-uu"] + PAT),
    "ffs -j4 fifo": ("fifo", [FFS, "-j4", "-uu"] + PAT),
    "ffs -j4 steal": ("steal", [FFS, "-j4", "-uu"] + PAT),
    "ffs -j4 lifo,dirfirst": ("lifo,dirfirst", [FFS, "-j4", "-uu"] + PAT),
    "ffs -j4 steal,dirfirst": ("steal,dirfirst", [FFS, "-j4", "-uu"] + PAT),
    "ffs -j4 shuffle": ("shuffle", [FFS, "-j4", "-uu"] + PAT),
    "rg -j4": (None, [RG, "-j4", "-uu"] + PAT),
    "ffs -j8 lifo": ("lifo", [FFS, "-j8", "-uu"] + PAT),
    "rg -j8": (None, [RG, "-j8", "-uu"] + PAT),
}

def pageins():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    return int(re.search(r"Pageins:\s+(\d+)", out).group(1))

def main():
    out, rounds, pct = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    names = list(CMDS) if len(sys.argv) < 5 else sys.argv[4].split(";")
    res = {n: [] for n in names}
    for r in range(rounds):
        order = names if r % 2 == 0 else names[::-1]
        for n in order:
            mode, argv = CMDS[n]
            if pct != "0": subprocess.run([EVICT, L, pct], capture_output=True, check=True)
            env = dict(os.environ)
            if mode: env["FFS_WALK"] = mode
            p0 = pageins(); t0 = time.perf_counter()
            subprocess.run(argv, stdout=subprocess.DEVNULL, env=env, check=True)
            t = time.perf_counter() - t0; p = pageins() - p0
            res[n].append([t, p])
            print(f"round {r} {n:24s} {t:6.2f}s {p:7d} pageins", flush=True)
        json.dump({"pct_evicted": int(pct), "commands": {n: CMDS[n][1] for n in names},
                   "env": {n: CMDS[n][0] for n in names}, "runs": res}, open(out, "w"), indent=1)

main()
