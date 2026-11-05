# Go vs Rails — middleware de APIs

```
date=2026-11-05T11:02:22-03:00
host=Linux PC 5.15.167.4-microsoft-standard-WSL2 #1 SMP Tue Nov 5 00:21:55 UTC 2024 x86_64 x86_64 x86_64 GNU/Linux
cpus_host=12
MW_CPUS=2 MW_MEM=1g RAILS_MAX_THREADS=16
BASE_LATENCY_MS=30 JITTER_MS=20 SLOW_RATE=0 ERROR_RATE=0
DURATION=60s WARMUP=20s
```

## Boot e footprint

| impl | boot (ms) | imagem (MB) | memória ociosa |
|---|---:|---:|---:|
| go | 380 | 8 | 2.688MiB |
| rails | 1359 | 514 | 88.47MiB |

## Como ler

- Latências em ms, medidas pelo k6 (inclui a latência simulada dos domínios, ~30–50 ms por chamada).
- **descartadas** > 0 significa que o servidor não acompanhou a taxa pedida: é o ponto de saturação.
- CPU % do `docker stats` é relativo a 1 core (200% = 2 cores cheios).
- O número que mais importa: maior taxa em que p99 fica abaixo do SLO e erros ≈ 0, e quanta CPU isso custou.
