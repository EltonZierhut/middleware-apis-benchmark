#!/usr/bin/env bash
# Executa a bateria completa: para cada implementação (go, rails, node), sobe só ela,
# mede tempo de boot, aquece, roda cada taxa de carga coletando CPU/memória
# e grava tudo em results/. No fim gera results/report.md.
#
# Uso:
#   ./run.sh                                 # bateria padrão
#   RATES="100 300 600" SCENARIOS="mixed" DURATION=30s ./run.sh
#   SLOW_RATE=0.1 ERROR_RATE=0.05 ./run.sh   # cenário de resiliência (domínio lento/instável)
set -euo pipefail
cd "$(dirname "$0")"

TARGETS="${TARGETS:-go rails node}"
SCENARIOS="${SCENARIOS:-health list show mixed}"
RATES="${RATES:-100 250 500 1000 2000}"
DURATION="${DURATION:-60s}"
WARMUP="${WARMUP:-20s}"
TAG="${TAG:-$(date +%Y%m%d-%H%M%S)}"
OUTDIR="results/$TAG"
mkdir -p "$OUTDIR"
# o k6 roda no container como uid 12345: precisa poder gravar os resumos aqui
chmod a+rwx "$OUTDIR" results

declare -A PORT=( [go]=8080 [rails]=3000 [node]=3001 )

echo "==> build"
docker compose build upstream $TARGETS >/dev/null
docker compose pull k6 >/dev/null 2>&1 || true

echo "==> upstream mock"
docker compose up -d upstream >/dev/null
until curl -fsS localhost:9000/health >/dev/null 2>&1; do sleep 0.2; done

cat > "$OUTDIR/env.txt" <<EOF
date=$(date -Iseconds)
host=$(uname -a)
cpus_host=$(nproc)
MW_CPUS=${MW_CPUS:-2} MW_MEM=${MW_MEM:-1g} RAILS_MAX_THREADS=${RAILS_MAX_THREADS:-16}
BASE_LATENCY_MS=${BASE_LATENCY_MS:-30} JITTER_MS=${JITTER_MS:-20} SLOW_RATE=${SLOW_RATE:-0} ERROR_RATE=${ERROR_RATE:-0}
DURATION=$DURATION WARMUP=$WARMUP
EOF

for t in $TARGETS; do
  for other in $TARGETS; do [[ $other != "$t" ]] && docker compose stop "$other" >/dev/null 2>&1 || true; done

  echo "==> [$t] boot"
  docker compose rm -sf "$t" >/dev/null 2>&1 || true
  start=$(date +%s%N)
  docker compose up -d "$t" >/dev/null
  until curl -fsS "localhost:${PORT[$t]}/health" >/dev/null 2>&1; do sleep 0.05; done
  boot_ms=$(( ($(date +%s%N) - start) / 1000000 ))
  cid=$(docker compose ps -q "$t")
  img=$(docker inspect -f '{{.Image}}' "$cid")
  img_mb=$(( $(docker image inspect -f '{{.Size}}' "$img") / 1024 / 1024 ))
  idle_mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$cid" | awk '{print $1}')
  echo "{\"target\":\"$t\",\"boot_ms\":$boot_ms,\"image_mb\":$img_mb,\"idle_mem\":\"$idle_mem\"}" > "$OUTDIR/$t-meta.json"
  echo "    boot=${boot_ms}ms image=${img_mb}MB idle_mem=$idle_mem"

  echo "==> [$t] warmup ($WARMUP)"
  docker compose run --rm -e TARGET="http://$t:${PORT[$t]}" -e SCENARIO=mixed -e RATE=200 \
    -e DURATION="$WARMUP" -e OUT=/results/.warmup.json k6 run --quiet /scripts/load.js >/dev/null 2>&1 || true

  for s in $SCENARIOS; do
    for r in $RATES; do
      name="$t-$s-$r"
      echo "==> [$t] scenario=$s rate=$r/s"
      # amostra CPU/memória do container durante o teste
      ( while true; do
          docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}}' "$cid" 2>/dev/null || break
          sleep 1
        done ) > "$OUTDIR/$name.stats.csv" &
      spid=$!
      docker compose run --rm -e TARGET="http://$t:${PORT[$t]}" -e SCENARIO="$s" -e RATE="$r" \
        -e DURATION="$DURATION" -e OUT="/results/$TAG/$name.json" k6 run --quiet /scripts/load.js >/dev/null 2>&1 || true
      kill "$spid" 2>/dev/null || true; wait "$spid" 2>/dev/null || true
      [[ -s "$OUTDIR/$name.json" ]] || echo "    AVISO: k6 não gravou $OUTDIR/$name.json"
      sleep 3   # deixa filas e GC assentarem entre as rodadas
    done
  done
  docker compose stop "$t" >/dev/null
done

python3 report.py "$OUTDIR"
echo "==> relatório: $OUTDIR/report.md"
