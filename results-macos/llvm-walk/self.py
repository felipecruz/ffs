# self.py OUT.json: each command 4x back to back, no eviction; first run dropped.
import json, os, sys, time, subprocess, importlib.util
spec = importlib.util.spec_from_file_location("cold", os.path.join(os.path.dirname(__file__), "cold.py"))
src = open(spec.origin).read().replace("\nmain()\n", "\n")
g = {"__file__": spec.origin}; exec(src, g)
names = sys.argv[2].split(";")
res = {n: [] for n in names}
for p in range(2):
    for n in (names if p == 0 else names[::-1]):
        mode, argv = g["CMDS"][n]
        env = dict(os.environ)
        if mode: env["FFS_WALK"] = mode
        for i in range(4):
            p0 = g["pageins"](); t0 = time.perf_counter()
            subprocess.run(argv, stdout=subprocess.DEVNULL, env=env, check=True)
            t = time.perf_counter() - t0; pi = g["pageins"]() - p0
            if i: res[n].append([t, pi])
            print(f"pass {p} {n:24s} run {i} {t:6.2f}s {pi:7d}", flush=True)
json.dump({"pct_evicted": 0, "back_to_back": 4, "runs": res}, open(sys.argv[1], "w"), indent=1)
