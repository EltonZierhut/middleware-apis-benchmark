#!/usr/bin/env python3
"""Consolida os resumos do k6 + amostras do docker stats em results/<tag>/report.md e report.csv."""
import csv
import glob
import json
import os
import re
import sys

UNITS = {"B": 1 / 1024 / 1024, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024, "kB": 1 / 1000, "MB": 1, "GB": 1000}


def mem_mb(s):
    m = re.match(r"([\d.]+)\s*([A-Za-z]+)", s.strip())
    return float(m.group(1)) * UNITS.get(m.group(2), 1) if m else 0.0


def load_stats(path):
    cpu, mem = [], []
    if not os.path.exists(path):
        return 0, 0, 0
    for line in open(path):
        parts = line.strip().split(",")
        if len(parts) < 2 or "%" not in parts[0]:
            continue
        cpu.append(float(parts[0].rstrip("%")))
        mem.append(mem_mb(parts[1].split("/")[0]))
    if not cpu:
        return 0, 0, 0
    return sum(cpu) / len(cpu), max(cpu), max(mem)


def main(outdir):
    rows = []
    for f in sorted(glob.glob(os.path.join(outdir, "*-*-*.json"))):
        base = os.path.basename(f)[:-5]
        if base.endswith("-meta"):
            continue
        target, scenario, rate = base.rsplit("-", 2)
        d = json.load(open(f))
        m = d["metrics"]
        dur = m["http_req_duration"]["values"]
        reqs = m["http_reqs"]["values"]
        failed = m.get("http_req_failed", {}).get("values", {}).get("rate", 0)
        dropped = m.get("dropped_iterations", {}).get("values", {}).get("count", 0)
        cpu_avg, cpu_max, mem_max = load_stats(os.path.join(outdir, base + ".stats.csv"))
        rows.append({
            "target": target, "scenario": scenario, "rate": int(rate),
            "achieved_rps": round(reqs["rate"], 1),
            "p50_ms": round(dur["med"], 1), "p95_ms": round(dur["p(95)"], 1),
            "p99_ms": round(dur["p(99)"], 1), "max_ms": round(dur["max"], 1),
            "errors_pct": round(failed * 100, 2), "dropped": int(dropped),
            "cpu_avg_pct": round(cpu_avg, 1), "cpu_max_pct": round(cpu_max, 1),
            "mem_max_mb": round(mem_max, 1),
        })
    rows.sort(key=lambda r: (r["scenario"], r["rate"], r["target"]))

    order = {"go": 0, "rails": 1, "node": 2}
    metas = sorted((json.load(open(f)) for f in glob.glob(os.path.join(outdir, "*-meta.json"))),
                   key=lambda m: order.get(m["target"], 99))

    with open(os.path.join(outdir, "report.csv"), "w", newline="") as fh:
        if rows:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)

    env = open(os.path.join(outdir, "env.txt")).read() if os.path.exists(os.path.join(outdir, "env.txt")) else ""
    names = {"go": "Go", "rails": "Rails", "node": "Node.js"}
    title = " vs ".join(names.get(m["target"], m["target"]) for m in metas) or "Benchmark"
    lines = [f"# {title} — middleware de APIs", "", "```", env.strip(), "```", "",
             "## Boot e footprint", "", "| impl | boot (ms) | imagem (MB) | memória ociosa |", "|---|---:|---:|---:|"]
    for mt in metas:
        lines.append(f"| {mt['target']} | {mt['boot_ms']} | {mt['image_mb']} | {mt['idle_mem']} |")

    for scenario in sorted({r["scenario"] for r in rows}):
        lines += ["", f"## Cenário `{scenario}`", "",
                  "| impl | alvo rps | rps real | p50 | p95 | p99 | max | erros % | descartadas | CPU média % | CPU máx % | mem máx MB |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for r in [x for x in rows if x["scenario"] == scenario]:
            lines.append(
                f"| {r['target']} | {r['rate']} | {r['achieved_rps']} | {r['p50_ms']} | {r['p95_ms']} | {r['p99_ms']} | "
                f"{r['max_ms']} | {r['errors_pct']} | {r['dropped']} | {r['cpu_avg_pct']} | {r['cpu_max_pct']} | {r['mem_max_mb']} |")

    lines += ["", "## Como ler", "",
              "- Latências em ms, medidas pelo k6 (inclui a latência simulada dos domínios, ~30–50 ms por chamada).",
              "- **descartadas** > 0 significa que o servidor não acompanhou a taxa pedida: é o ponto de saturação.",
              "- CPU % do `docker stats` é relativo a 1 core (200% = 2 cores cheios).",
              "- O número que mais importa: maior taxa em que p99 fica abaixo do SLO e erros ≈ 0, e quanta CPU isso custou."]
    with open(os.path.join(outdir, "report.md"), "w") as fh:
        fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
