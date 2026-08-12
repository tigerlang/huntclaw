import subprocess, time, statistics, shutil, os, sys, random
from collections import defaultdict

HC = os.environ.get("HUNTCLAW_BIN", "./zig-out/bin/huntclaw")
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "huntclaw_bench")

def timed_run(cmd, shell=False):
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, text=True, shell=shell)
    t1 = time.perf_counter()
    return (t1 - t0) * 1000, r

def bench(name, cmd, n=25, warmup=5, shell=False, verify=None):
    for _ in range(warmup):
        timed_run(cmd, shell)
    times = []
    last = None
    for _ in range(n):
        t, r = timed_run(cmd, shell)
        times.append(t)
        last = r
    times.sort()
    result = {
        "name": name,
        "min": times[0],
        "p50": statistics.median(times),
        "p90": times[int(len(times) * 0.9)],
        "max": times[-1],
        "mean": statistics.mean(times),
        "stdev": statistics.stdev(times) if len(times) > 1 else 0.0,
        "n": n,
    }
    ok = True
    if verify is not None:
        ok = verify(last)
    flag = "" if ok else "  [VERIFY FAILED]"
    print(f"{name:36s} min={result['min']:8.2f}  p50={result['p50']:8.2f}  p90={result['p90']:8.2f}  "
          f"max={result['max']:8.2f}  mean={result['mean']:8.2f}  sd={result['stdev']:6.2f}  (n={n}){flag}")
    return result

def bench_replace(name, setup, cmd, n=15, warmup=3, shell=False, verify=None):
    for _ in range(warmup):
        setup()
        timed_run(cmd, shell)
    times = []
    for _ in range(n):
        setup()
        t, _ = timed_run(cmd, shell)
        times.append(t)
    times.sort()
    result = {
        "name": name,
        "min": times[0],
        "p50": statistics.median(times),
        "p90": times[int(len(times) * 0.9)],
        "max": times[-1],
        "mean": statistics.mean(times),
        "stdev": statistics.stdev(times) if len(times) > 1 else 0.0,
        "n": n,
    }
    ok = True
    if verify is not None:
        ok = verify()
    flag = "" if ok else "  [VERIFY FAILED]"
    print(f"{name:36s} min={result['min']:8.2f}  p50={result['p50']:8.2f}  p90={result['p90']:8.2f}  "
          f"max={result['max']:8.2f}  mean={result['mean']:8.2f}  sd={result['stdev']:6.2f}  (n={n}){flag}")
    return result

def build_datasets():
    for sub in ["large", "manyfiles", "sparse", "dense"]:
        os.makedirs(f"{BASE}/{sub}", exist_ok=True)

    random.seed(2026)
    words = ["zebra", "orange", "crystal", "harbor", "velvet", "marble", "signal", "copper", "TARGET", "engine", "vapor", "ribbon", "current", "static", "hollow"]
    with open(f"{BASE}/large/data.txt", "w") as f:
        for _ in range(620000):
            f.write(" ".join(random.choice(words) for _ in range(10)) + "\n")

    random.seed(77)
    words = ["struct", "enum", "trait", "impl", "match", "TARGET", "yield", "async", "await", "crate", "module", "borrow", "lifetime", "generic"]
    for i in range(4200):
        with open(f"{BASE}/manyfiles/mod_{i}.rs", "w") as f:
            nlines = random.randint(15, 100)
            for _ in range(nlines):
                f.write(" ".join(random.choice(words) for _ in range(9)) + "\n")

    random.seed(555)
    words = ["north", "south", "east", "west", "ridge", "delta", "summit", "canyon", "plateau", "basin"]
    with open(f"{BASE}/sparse/data.txt", "w") as f:
        for i in range(340000):
            if i % 6800 == 0:
                f.write("TARGET " + " ".join(random.choice(words) for _ in range(9)) + "\n")
            else:
                f.write(" ".join(random.choice(words) for _ in range(11)) + "\n")

    with open(f"{BASE}/dense/data.txt", "w") as f:
        for _ in range(230000):
            f.write("TARGET one TARGET two TARGET three TARGET four TARGET\n")

def occurrence_count(path, pattern="TARGET"):
    with open(path) as f:
        return f.read().count(pattern)

def run_search(rows):
    print("=" * 100)
    print("SEARCH")
    print("=" * 100)

    large_n = occurrence_count(f"{BASE}/large/data.txt")
    print(f"\n-- large: {large_n} occurrences --")
    r = bench("huntclaw -p -q", [HC, "-p", "-q", "TARGET", f"{BASE}/large/data.txt"])
    rows.append(("search-large", "huntclaw", r["min"]))
    r = bench("ripgrep -o | wc -l", f"rg -o TARGET {BASE}/large/data.txt | wc -l", shell=True)
    rows.append(("search-large", "ripgrep", r["min"]))
    r = bench("GNU grep -o | wc -l", f"grep -o TARGET {BASE}/large/data.txt | wc -l", shell=True)
    rows.append(("search-large", "GNU grep", r["min"]))

    print(f"\n-- manyfiles: 4200 files --")
    r = bench("huntclaw -p -q", [HC, "-p", "-q", "TARGET", f"{BASE}/manyfiles"])
    rows.append(("search-many", "huntclaw", r["min"]))
    r = bench("ripgrep -c", ["rg", "-c", "TARGET", f"{BASE}/manyfiles"])
    rows.append(("search-many", "ripgrep", r["min"]))
    r = bench("GNU grep -r -o | wc -l", f"grep -r -o TARGET {BASE}/manyfiles | wc -l", shell=True)
    rows.append(("search-many", "GNU grep", r["min"]))

    sparse_n = occurrence_count(f"{BASE}/sparse/data.txt")
    print(f"\n-- sparse: {sparse_n} occurrences --")
    r = bench("huntclaw -p -q", [HC, "-p", "-q", "TARGET", f"{BASE}/sparse/data.txt"])
    rows.append(("search-sparse", "huntclaw", r["min"]))
    r = bench("ripgrep -o | wc -l", f"rg -o TARGET {BASE}/sparse/data.txt | wc -l", shell=True)
    rows.append(("search-sparse", "ripgrep", r["min"]))
    r = bench("GNU grep -o | wc -l", f"grep -o TARGET {BASE}/sparse/data.txt | wc -l", shell=True)
    rows.append(("search-sparse", "GNU grep", r["min"]))

    dense_n = occurrence_count(f"{BASE}/dense/data.txt")
    print(f"\n-- dense: {dense_n} occurrences --")
    r = bench("huntclaw -p -q", [HC, "-p", "-q", "TARGET", f"{BASE}/dense/data.txt"])
    rows.append(("search-dense", "huntclaw", r["min"]))
    r = bench("ripgrep -o | wc -l", f"rg -o TARGET {BASE}/dense/data.txt | wc -l", shell=True)
    rows.append(("search-dense", "ripgrep", r["min"]))
    r = bench("GNU grep -o | wc -l", f"grep -o TARGET {BASE}/dense/data.txt | wc -l", shell=True)
    rows.append(("search-dense", "GNU grep", r["min"]))

def run_replace(rows):
    print("=" * 100)
    print("REPLACE")
    print("=" * 100)

    large_n = occurrence_count(f"{BASE}/large/data.txt")

    def setup_large():
        shutil.copyfile(f"{BASE}/large/data.txt", f"{BASE}/large/data_r.txt")

    def verify_large():
        c = open(f"{BASE}/large/data_r.txt").read()
        return c.count("TARGET") == 0 and c.count("REPLACED") == large_n

    print(f"\n-- large: {large_n} occurrences --")
    r = bench_replace("huntclaw", setup_large, [HC, "-q", "TARGET", "REPLACED", f"{BASE}/large/data_r.txt"], verify=verify_large)
    rows.append(("replace-large", "huntclaw", r["min"]))
    r = bench_replace("sd", setup_large, ["sd", "TARGET", "REPLACED", f"{BASE}/large/data_r.txt"], verify=verify_large)
    rows.append(("replace-large", "sd", r["min"]))
    r = bench_replace("sed -i", setup_large, ["sed", "-i", "s/TARGET/REPLACED/g", f"{BASE}/large/data_r.txt"], verify=verify_large)
    rows.append(("replace-large", "GNU sed", r["min"]))

    def setup_many():
        if os.path.exists(f"{BASE}/manyfiles_r"):
            shutil.rmtree(f"{BASE}/manyfiles_r")
        shutil.copytree(f"{BASE}/manyfiles", f"{BASE}/manyfiles_r")

    def verify_many():
        r1 = subprocess.run(["grep", "-r", "-l", "TARGET", f"{BASE}/manyfiles_r"], capture_output=True, text=True)
        r2 = subprocess.run(["grep", "-r", "-l", "REPLACED", f"{BASE}/manyfiles_r"], capture_output=True, text=True)
        remaining = len(r1.stdout.strip().splitlines()) if r1.stdout.strip() else 0
        replaced = len(r2.stdout.strip().splitlines()) if r2.stdout.strip() else 0
        return remaining == 0 and replaced > 4000

    print(f"\n-- manyfiles: 4200 files --")
    r = bench_replace("huntclaw", setup_many, [HC, "-q", "TARGET", "REPLACED", f"{BASE}/manyfiles_r"], n=10, verify=verify_many)
    rows.append(("replace-many", "huntclaw", r["min"]))
    r = bench_replace("sd (find|xargs)", setup_many, f"find {BASE}/manyfiles_r -type f | xargs sd TARGET REPLACED", shell=True, n=10, verify=verify_many)
    rows.append(("replace-many", "sd", r["min"]))
    r = bench_replace("sed -i (find|xargs)", setup_many, f"find {BASE}/manyfiles_r -type f | xargs sed -i s/TARGET/REPLACED/g", shell=True, n=10, verify=verify_many)
    rows.append(("replace-many", "GNU sed", r["min"]))

    dense_n = occurrence_count(f"{BASE}/dense/data.txt")

    def setup_dense():
        shutil.copyfile(f"{BASE}/dense/data.txt", f"{BASE}/dense/data_r.txt")

    def verify_dense():
        c = open(f"{BASE}/dense/data_r.txt").read()
        return c.count("TARGET") == 0 and c.count("REPLACED") == dense_n

    print(f"\n-- dense: {dense_n} occurrences --")
    r = bench_replace("huntclaw", setup_dense, [HC, "-q", "TARGET", "REPLACED", f"{BASE}/dense/data_r.txt"], verify=verify_dense)
    rows.append(("replace-dense", "huntclaw", r["min"]))
    r = bench_replace("sd", setup_dense, ["sd", "TARGET", "REPLACED", f"{BASE}/dense/data_r.txt"], verify=verify_dense)
    rows.append(("replace-dense", "sd", r["min"]))
    r = bench_replace("sed -i", setup_dense, ["sed", "-i", "s/TARGET/REPLACED/g", f"{BASE}/dense/data_r.txt"], verify=verify_dense)
    rows.append(("replace-dense", "GNU sed", r["min"]))

def print_leaderboard(rows):
    print("=" * 100)
    print("LEADERBOARD")
    print("=" * 100)

    labels = {
        "search-large": "search large file",
        "search-many": "search many files",
        "search-sparse": "search sparse matches",
        "search-dense": "search dense matches",
        "replace-large": "replace large file",
        "replace-many": "replace many files",
        "replace-dense": "replace dense matches",
    }
    order = list(labels.keys())

    cats = defaultdict(list)
    for cat, tool, ms in rows:
        cats[cat].append((tool, ms))

    wins = defaultdict(int)
    for cat in order:
        items = sorted(cats[cat], key=lambda x: x[1])
        winner = items[0]
        wins[winner[0]] += 1
        others = ", ".join(f"{t}={m:.2f}ms" for t, m in items[1:])
        print(f"{labels[cat]:26s} -> {winner[0]:10s} {winner[1]:8.2f}ms   [{others}]")

    print()
    print("wins by tool:")
    for tool, c in sorted(wins.items(), key=lambda x: -x[1]):
        print(f"  {tool:12s} {c}")

def main():
    if os.path.exists(BASE):
        shutil.rmtree(BASE)
    os.makedirs(BASE)
    build_datasets()

    rows = []
    run_search(rows)
    run_replace(rows)
    print_leaderboard(rows)

    shutil.rmtree(BASE)

if __name__ == "__main__":
    main()
