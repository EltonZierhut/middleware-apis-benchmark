# middleware-apis-benchmark

Benchmark para decidir a stack (**Go**, **Ruby on Rails** ou **Node.js**) de um **middleware de APIs**.

Este repositório tem três implementações equivalentes do middleware, um mock dos serviços de domínio e
scripts de carga que medem as três nas mesmas condições.

---

## Contexto

O middleware é a camada que conecta as APIs internas de uma plataforma ao mundo externo:

- **Quem consome:** clientes e integrações (ERP, CRM, BI, data lake) pela API nova (`/platform`);
  agentes de IA via MCP Gateway; e, numa fase futura, os clientes das APIs legadas (contrato congelado).
- **Por onde entram:** todos passam pelo **API Gateway (Kong)**, que cuida de auth OAuth
  e roteamento. O gateway chama **somente** o middleware.
- **De quem o middleware lê:** Monolito, Contatos, Automação, Multicanalidade, Data lake e demais serviços.
- **Responsabilidades:** contratos OpenAPI, filtros, paginação, resiliência por domínio e compatibilidade do
  legado (fase futura).

Premissas do projeto:

- Padrões de request, response e filtros criados uma vez e reaproveitados.
- Deploy independente do monolito e dos times de domínio.
- APIs legadas continuam respondendo (sem sunset); dados novos só na API nova.
- Camada temporária, aposentada à medida que os domínios forem desacoplados rumo a API first.

### A pergunta que o benchmark responde

> Para esse papel (muito I/O, fan-out entre domínios, transformação de JSON, timeouts por domínio),
> quanto de latência, throughput e custo de infraestrutura cada stack entrega com o mesmo orçamento de CPU e memória?

Performance não é o único critério. Veja [O que o benchmark não responde](#o-que-o-benchmark-não-responde).

---

## Arquitetura do benchmark

```
k6 ──► middleware (go | rails | node) ──► upstream-mock (Contatos · Automação · Multicanalidade)
```

O Kong fica de fora de propósito: ele é igual em todas as opções e só somaria ruído à medição.

| Rota | Representa no projeto | Estressa |
|---|---|---|
| `GET /health` | piso do framework | overhead de HTTP, roteamento e JSON |
| `GET /platform/contacts?page&page_size&filter[...]` | contratos OpenAPI, filtros, paginação | 1 chamada upstream (~100 registros), parse, transformação para o contrato, filtro, serialização |
| `GET /platform/contacts/{id}` | agregação entre domínios, resiliência por domínio | 3 chamadas **em paralelo**: Contatos obrigatório (timeout 1 s); Automação e Multicanalidade opcionais (timeout 300 ms, degradam para `null` e entram em `meta.degraded`) |

Filtros aceitos: `filter[lead_stage]`, `filter[tag]`, `filter[email_domain]`. `page_size` vai de 1 a 100 (padrão 25).

### As implementações

- **Go (`go-middleware/`):** só stdlib (`net/http`, `encoding/json`), goroutines no fan-out. Zero dependências.
- **Rails 8 em modo API (`rails-middleware/`):** só Action Controller, Puma (1 processo por CPU, 16 threads),
  YJIT, jemalloc, `net-http-persistent` (keep-alive) e `concurrent-ruby` no fan-out.
  É um Rails configurado como iria para produção, não um Rails de propósito lento.
- **Node.js 22 (`node-middleware/`):** só stdlib (`node:http`, `node:cluster`), `http.Agent` com keep-alive,
  `Promise.allSettled` no fan-out e 1 processo por CPU (`WEB_CONCURRENCY`, como o Puma). Zero dependências.

As três devolvem o mesmo JSON. O `parity.sh` confere isso antes de qualquer medição.

---

## Instalação

### Pré-requisitos

| Ferramenta | Para quê | Versão |
|---|---|---|
| Docker + Docker Compose v2 | sobe mock, middlewares e k6 | Docker 24+ |
| `curl` | health checks | qualquer |
| `jq` | comparação de JSON no `parity.sh` | 1.6+ |
| `python3` | gera o relatório | 3.9+ |

O k6 roda em container (`grafana/k6`), então não precisa instalar.

**macOS**

```bash
brew install --cask docker   # ou Docker Desktop / OrbStack
brew install jq python
```

**Ubuntu / Debian**

```bash
# Docker: https://docs.docker.com/engine/install/ubuntu/
sudo apt-get update && sudo apt-get install -y jq curl python3
sudo usermod -aG docker $USER   # depois, saia e entre de novo na sessão
```

**Windows:** use WSL2 com Ubuntu e siga as instruções acima, com o Docker Desktop integrado ao WSL.

### Clonar e preparar

```bash
git clone https://github.com/EltonZierhut/middleware-apis-benchmark.git
cd middleware-apis-benchmark
chmod +x run.sh parity.sh
docker compose build
```

O primeiro build do Rails baixa as gems e leva alguns minutos.

> **Gemfile.lock:** o repositório não traz o lock. Para fixar versões entre execuções, gere uma vez com
> `docker compose run --rm --no-deps rails bundle lock` e faça commit do `rails-middleware/Gemfile.lock`.

---

## Como rodar

### 1. Conferir paridade dos contratos

```bash
docker compose up -d upstream go rails node
./parity.sh            # compara rails e node com o go; IMPLS="node" ./parity.sh para só uma
docker compose down
```

Todas as linhas devem sair `OK`. Se aparecer `DIFF`, corrija antes de medir: comparar respostas diferentes invalida o resultado.

### 2. Bateria completa

```bash
./run.sh
```

Com os padrões (3 stacks × 4 cenários × 5 taxas) leva cerca de 65 minutos. O relatório sai em `results/<data-hora>/report.md` e `report.csv`.

### Exemplos

```bash
# rodada rápida para validar o setup
RATES="100 500 1000" SCENARIOS="mixed" DURATION=30s ./run.sh

# resiliência: 10% das chamadas à Automação levam 1 s e 5% da Multicanalidade dão 503
SLOW_RATE=0.1 ERROR_RATE=0.05 SCENARIOS="show" TAG=resiliencia ./run.sh

# simular o tamanho de pod de produção
MW_CPUS=1 MW_MEM=512m TAG=pod-pequeno ./run.sh

# só uma das stacks
TARGETS=node ./run.sh
```

### Parâmetros

| Variável | Padrão | Efeito |
|---|---|---|
| `TARGETS` | `go rails node` | quais implementações medir |
| `SCENARIOS` | `health list show mixed` | `mixed` = 70% list / 30% show |
| `RATES` | `100 250 500 1000 2000` | taxas em req/s, modelo aberto (`constant-arrival-rate`) |
| `DURATION` / `WARMUP` | `60s` / `20s` | duração de cada rodada / aquecimento (YJIT, pools de conexão) |
| `MW_CPUS` / `MW_MEM` | `2` / `1g` | orçamento de cada middleware; use o tamanho do pod de produção |
| `RAILS_MAX_THREADS` | `16` | threads por processo Puma |
| — | — | Node usa `WEB_CONCURRENCY = MW_CPUS` processos no cluster |
| `BASE_LATENCY_MS` / `JITTER_MS` | `30` / `20` | latência simulada dos domínios; calibre com o p50 real das APIs internas |
| `SLOW_RATE` / `SLOW_MS` | `0` / `1000` | fração de chamadas lentas à Automação e quanto demoram |
| `ERROR_RATE` | `0` | fração de chamadas à Multicanalidade que retornam 503 |
| `TAG` | data e hora | nome da pasta em `results/` |

### Rodar sem Docker (desenvolvimento)

Útil para depurar uma das implementações. Não use para medir.

```bash
# mock (Go 1.22+)
cd upstream-mock && go run . &          # porta 9000

# Go
cd go-middleware && UPSTREAM_URL=http://localhost:9000 go run . &   # porta 8080

# Rails (Ruby 3.3+)
cd rails-middleware && bundle install
RAILS_ENV=production RUBY_YJIT_ENABLE=1 UPSTREAM_URL=http://localhost:9000 PORT=3000 \
  bundle exec puma -C config/puma.rb

# Node (22+)
cd node-middleware && UPSTREAM_URL=http://localhost:9000 WEB_CONCURRENCY=2 node server.js   # porta 3001
```

---

## Como ler o resultado

O `report.md` traz:

- **Boot e footprint:** tempo até o `/health` responder, tamanho da imagem e memória ociosa.
  Importam para autoscaling e deploy independente.
- **Por cenário e taxa:** rps real, p50/p95/p99/max, % de erro, iterações descartadas, CPU média/máxima e memória máxima.

Pontos de leitura:

- **Descartadas > 0** quer dizer que o servidor não acompanhou a taxa pedida. É o ponto de saturação.
- CPU % do `docker stats` é relativo a 1 core (200% = 2 cores cheios).
- A comparação que decide: **qual a maior taxa sustentada com p99 dentro do SLO e erro perto de zero, e quantos pods
  cada stack precisa** para o tráfego projetado do `/platform`. Converta isso em custo mensal.
- No cenário de resiliência, o `show` deve continuar com status 200 e latência perto de 300 ms nos casos degradados.
  Se crescer além disso, o timeout por domínio não está segurando.

### Cuidados para o resultado valer

1. Rode numa máquina dedicada, de preferência da mesma família de instância de produção. Num notebook,
   k6 e mock disputam CPU com o middleware. O ideal é o k6 em outra máquina.
2. Um middleware por vez. O `run.sh` já faz isso.
3. Repita cada bateria pelo menos 3 vezes e olhe a variação antes de concluir.
4. Calibre `BASE_LATENCY_MS` com a latência real dos serviços. Com upstream lento, a vantagem de CPU pesa menos
   e a capacidade de concorrência de I/O pesa mais.
5. Para testar outro desenho em Ruby, vale uma rodada com **Falcon + async** (fibers) no lugar de Puma + threads.
   O contrato e os scripts continuam os mesmos.

---

## Resultados

| Execução | Ambiente | Análise |
|---|---|---|
| 05/11/2026 | notebook WSL2, 12 CPUs, 2 CPUs / 1 GB por middleware | [análise para RFC](results/20261105-110216/ANALISE.md) · [relatório bruto](results/20261105-110216/report.md) |

> A execução de 05/11/2026 (só Go e Rails) não registrou latência: o k6 não teve permissão de escrita na pasta de
> resultados. A análise usa boot, footprint e as amostras de CPU e memória. O `run.sh` agora libera a escrita na
> pasta e avisa quando um resumo do k6 não for gravado.

---

## O que o benchmark não responde

Coloque estes pontos na mesma tabela da decisão:

- **Fluência do time** em cada stack e quem vai manter a camada. Ela é temporária, mas pode durar anos.
- **Ferramental de contrato OpenAPI:** `oapi-codegen` / `ogen` (Go), `rswag` / `committee` (Rails) e `openapi-typescript` / `express-openapi-validator` ou Fastify com JSON Schema (Node).
- **Compatibilidade do legado (fase futura):** se envolver reaproveitar código ou serializers do monolito Rails,
  isso favorece Rails. Se for só tradução de contrato, a stack pesa menos.
- **Operação:** observabilidade, bibliotecas de resiliência já usadas na empresa, imagem base e pipeline de deploy.

---

## Estrutura

```

upstream-mock/        mock dos domínios (Go), com latência, lentidão e erros configuráveis
go-middleware/        implementação em Go
rails-middleware/     implementação em Rails 8 API
node-middleware/      implementação em Node.js 22 (stdlib)
k6/load.js            cenários de carga
run.sh                orquestra build, boot, aquecimento, carga e coleta de métricas
report.py             gera report.md e report.csv
parity.sh             confere que as três implementações devolvem o mesmo JSON
results/              saída das execuções (ignorada pelo git)
```
