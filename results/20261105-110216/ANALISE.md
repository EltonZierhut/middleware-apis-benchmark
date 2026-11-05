## Benchmark de performance: Go vs Ruby on Rails para o middleware de APIs

### 1. Objetivo

Medir quanto de throughput, consumo de CPU, memória e custo de inicialização cada stack (Go e Rails) entrega
no papel do middleware de APIs, com o mesmo orçamento de recursos. O middleware faz muito I/O, fan-out entre
domínios, transformação de JSON e aplica timeout por domínio, e o teste foi montado para reproduzir esse perfil.

Performance é só um dos critérios da decisão. Fluência do time, ferramental OpenAPI, reaproveitamento de código
do monolito no legado e operação ficam fora deste teste e devem ser avaliados à parte.

### 2. O que foi testado

**Arquitetura do teste**

```
k6 (gerador de carga) ──► middleware (Go | Rails) ──► upstream-mock (Contatos · Automação · Multicanalidade)
```

O API Gateway (Kong) ficou de fora de propósito: ele é o mesmo nas duas opções e só somaria ruído.

**Implementações comparadas**

| | Go | Rails |
|---|---|---|
| Base | stdlib (`net/http`, `encoding/json`), sem dependências | Rails 8 em modo API (só Action Controller) |
| Servidor | servidor HTTP da stdlib | Puma, 2 processos × 16 threads |
| Runtime | `GOMAXPROCS=2` | Ruby com YJIT e jemalloc |
| Cliente upstream | `http.Transport` com keep-alive | `net-http-persistent` (keep-alive, pool 256) |
| Fan-out | goroutines | `concurrent-ruby` (futures em thread pool) |

As duas implementações devolvem o mesmo JSON. Antes da medição, o script `parity.sh` compara as respostas das
duas em 11 requisições (listagem com e sem filtros, paginação, página fora do intervalo, `page_size` inválido,
detalhe existente e inexistente) e só segue se todas forem idênticas.

**Rotas e o que cada uma estressa**

| Cenário | Rota | Representa | Carga de trabalho |
|---|---|---|---|
| `health` | `GET /health` | piso do framework | overhead de HTTP, roteamento e serialização, sem I/O |
| `list` | `GET /platform/contacts?page&page_size&filter[...]` | contratos, filtros e paginação | 1 chamada upstream (~100 registros), parse, transformação para o contrato público, filtro, serialização |
| `show` | `GET /platform/contacts/{id}` | agregação entre domínios e resiliência | 3 chamadas em paralelo: Contatos (obrigatório, timeout 1 s), Automação e Multicanalidade (opcionais, timeout 300 ms, degradam para `null`) |
| `mixed` | 70% `list` + 30% `show` | tráfego típico do `/platform` | mistura das duas anteriores |

No `list`, o k6 sorteia página entre 1 e 50, `page_size=25` e um de quatro filtros (nenhum, `lead_stage`, `tag`,
`email_domain`). No `show`, sorteia um entre 5.000 IDs.

**Condições da execução (05/11/2026)**

| Parâmetro | Valor |
|---|---|
| Máquina | notebook, Linux via WSL2, 12 CPUs; k6, mock e middleware na mesma máquina |
| Orçamento por middleware | 2 CPUs, 1 GB de memória (limite do container) |
| Latência simulada dos domínios | 30 ms + jitter de até 20 ms por chamada |
| Falhas e lentidão injetadas | nenhuma (`SLOW_RATE=0`, `ERROR_RATE=0`) |
| Modelo de carga | taxa de chegada constante (`constant-arrival-rate`): a taxa não cai quando o servidor fica lento |
| Duração | 20 s de aquecimento + 60 s por rodada, 3 s de pausa entre rodadas |

### 3. Sequência dos testes

O `run.sh` executa a bateria nesta ordem:

1. **Build** das imagens do mock, do Go e do Rails.
2. **Sobe o upstream-mock** e espera o `/health` dele responder.
3. **Para cada implementação** (primeiro Go, depois Rails), com a outra parada, para não disputarem a máquina:
   1. **Boot:** recria o container e mede o tempo até o `/health` responder. Registra o tamanho da imagem e a
      memória ociosa.
   2. **Aquecimento:** 20 s de cenário `mixed` a 200 req/s, para aquecer YJIT, pools de conexão e caches. O
      resultado é descartado.
   3. **Carga:** para cada cenário (`health`, `list`, `show`, `mixed`) e cada taxa (100, 250, 500, 1.000 e
      2.000 req/s), roda 60 s de k6 enquanto amostra CPU e memória do container com `docker stats`.
      São 20 rodadas por implementação.
   4. Para o container.
4. **Relatório:** o `report.py` consolida os resumos do k6 e as amostras de CPU e memória em `report.md` e
   `report.csv`.

### 4. Resultados

> **Limitação desta execução:** o k6 não gravou os resumos de latência e throughput. O container do k6 roda como
> o usuário `k6` (uid 12345) e não tinha permissão de escrita na pasta `results/<execução>/`, criada pelo usuário
> do host com permissão 755. O erro ficou oculto porque o `run.sh` descarta a saída do k6. Por isso não há p50,
> p95, p99, taxa de erro nem iterações descartadas nesta rodada. Os números abaixo vêm do boot e das amostras de
> CPU e memória, que foram coletadas normalmente. A saturação foi inferida do comportamento da CPU e da duração das
> rodadas (seção 5.2). A bateria precisa ser repetida com a correção para fechar a comparação de latência.

#### 4.1 Boot e footprint

| Implementação | Boot até o `/health` | Imagem | Memória ociosa (logo após o boot) |
|---|---:|---:|---:|
| Go | 380 ms | 8 MB | 2,7 MB |
| Rails | 1.359 ms | 514 MB | 88,5 MB |

#### 4.2 CPU média em regime (% de 1 core; o teto é 200%)

| Cenário | Taxa (req/s) | Go | Rails |
|---|---:|---:|---:|
| health | 100 | 1,8% | 7,9% |
| health | 500 | 6,6% | 21,0% |
| health | 1.000 | 11,1% | 43,9% |
| health | 2.000 | 16,7% | 102,0% |
| list | 100 | 10,9% | 14,3% |
| list | 500 | 51,9% | 54,0% |
| list | 1.000 | 91,1% | 74,9% ⚠ |
| list | 2.000 | 151,9% | 80,7% ⚠ |
| show | 100 | 5,9% | 16,3% |
| show | 500 | 21,2% | 62,1% |
| show | 1.000 | 39,2% | 86,4% ⚠ |
| show | 2.000 | 64,7% | 89,7% ⚠ |
| mixed | 100 | 11,4% | 16,2% |
| mixed | 500 | 42,8% | 61,8% |
| mixed | 1.000 | 77,1% | 86,7% ⚠ |
| mixed | 2.000 | 130,2% | 90,9% ⚠ |

⚠ = rodada em que o Rails não acompanhou a taxa pedida (ver 5.2). Nessas linhas a CPU não corresponde à taxa
da coluna, e sim ao máximo que o Rails conseguiu processar.

#### 4.3 Custo de CPU por requisição (rodadas sem saturação)

| Cenário | Go | Rails | Rails / Go |
|---|---:|---:|---:|
| health | 0,08–0,13 ms | 0,42–0,50 ms | ~4× |
| list | 0,76–1,04 ms | 1,08–1,13 ms | ~1,1× |
| show | 0,32–0,42 ms | 1,24–1,40 ms | ~3× |
| mixed | 0,65–0,86 ms | 1,24–1,33 ms | ~1,5× |

Faixas tiradas das taxas de 250 a 2.000 req/s no Go e de 250 a 500 req/s no Rails. O custo por requisição cai
com a taxa porque o overhead fixo do processo se dilui.

#### 4.4 Memória máxima sob carga

| Cenário | Go (100 → 2.000 req/s) | Rails (100 → 2.000 req/s) |
|---|---:|---:|
| health | 8 → 40 MB | 170 → 197 MB |
| list | 34 → 87 MB | 192 → 218 MB |
| show | 58 → 102 MB | 193 → 211 MB |
| mixed | 61 → 82 MB | 230 → 260 MB |

#### 4.5 Taxa máxima sustentada (estimada)

| Implementação | `list` / `show` / `mixed` | `health` |
|---|---|---|
| Go | acompanhou 2.000 req/s em todos os cenários, usando no máximo ~76% do orçamento de CPU | 2.000 req/s com 8% do orçamento |
| Rails | saturou entre 500 e 1.000 req/s; teto estimado de ~700–800 req/s | 2.000 req/s com ~51% do orçamento |

### 5. Análise dos resultados

#### 5.1 Boot e footprint

O Go sobe 3,6× mais rápido, tem imagem 64× menor e ocupa uma fração da memória. O binário estático roda numa
imagem mínima, enquanto o Rails carrega o interpretador Ruby, as gems e o framework na memória de cada processo
Puma. Isso pesa em autoscaling, porque um pod novo atende tráfego antes, e no tempo de deploy e pull de imagem.
Em valores absolutos, 1,4 s de boot e ~200–260 MB por pod estão dentro do aceitável para a maioria dos cenários de
produção. A diferença vira custo quando o número de pods cresce.

#### 5.2 O Rails satura por concorrência, não por CPU

É o resultado mais importante da rodada. A partir de 1.000 req/s nos cenários com upstream (`list`, `show`,
`mixed`), o Rails mostra três sinais de saturação:

1. **A CPU estabiliza abaixo do teto.** Ela para em ~75–90% (menos de 1 dos 2 cores) tanto a 1.000 quanto a
   2.000 req/s. Se o Rails estivesse acompanhando a carga, a CPU dobraria junto com a taxa, como acontece no Go.
2. **A rodada dura mais que 60 s.** As rodadas saturadas tiveram 41 a 45 amostras de CPU, contra 30–31 nas
   demais. Depois dos 60 s de carga, a CPU cai para ~20% e fica assim por ~15 s: é o k6 esperando as requisições
   que ficaram enfileiradas terminarem (período de *graceful stop*).
3. **O custo aparente por requisição despenca** (de ~1,1 ms para ~0,4 ms). Não é ganho de eficiência: o Rails
   processou bem menos requisições do que a taxa pedida.

A causa é o modelo de concorrência. Com 2 processos × 16 threads, o Rails atende no máximo 32 requisições ao
mesmo tempo. Cada thread fica presa durante a chamada ao upstream (30–50 ms). Pela Lei de Little, o teto é de
cerca de 32 / 0,04 s ≈ 800 req/s, o que bate com os ~700–800 req/s calculados pela CPU em regime
(~80% de CPU ÷ ~1,1 ms por requisição). Acima disso, as requisições excedentes ficam na fila e a latência cresce
sem limite.

O Go não tem esse teto. Cada requisição roda numa goroutine barata e a espera de I/O não ocupa uma thread do
sistema. O limite passa a ser a CPU, que a 2.000 req/s ainda tinha ~25% de folga no `list` e ~68% no `show`.

**Implicação:** o teto do Rails depende de quantas threads existem e da latência dos domínios, não do tamanho do
pod. Se os serviços reais responderem mais devagar que os 30–50 ms simulados, o teto cai na mesma proporção. Dá
para subir o teto aumentando `RAILS_MAX_THREADS` ou trocando para um servidor baseado em fibers (Falcon + async),
ao custo de mais memória e mais disputa pelo GVL. Isso precisa ser medido antes de ser assumido.

#### 5.3 Custo de CPU por rota

- **`health` (piso do framework):** o Rails gasta ~4× mais CPU por requisição. É o custo fixo da pilha Rack,
  roteamento, middlewares do Action Controller e criação de objetos por requisição.
- **`list` (parse e transformação de JSON):** praticamente empate, com o Go só ~10% mais barato. O trabalho dessa
  rota é decodificar ~100 registros, transformar e serializar. No Rails, o parse JSON é feito pela gem `json`,
  implementada em C. No Go, o `encoding/json` da stdlib usa reflection e é relativamente lento. As duas stacks
  acabam fazendo o trabalho pesado em código nativo com eficiência parecida. Um codificador JSON mais rápido no Go
  (`goccy/go-json`, `sonic` ou o `encoding/json/v2`) tende a abrir vantagem aqui.
- **`show` (fan-out para 3 domínios):** o Rails gasta ~3× mais CPU. Cada requisição cria 3 futures num thread
  pool, troca contexto entre threads e disputa o GVL. No Go, são 3 goroutines e um `WaitGroup`, com custo quase
  nulo.
- **`mixed` (70/30):** ~1,5× a favor do Go, a média ponderada das duas rotas.

Para o perfil real do `/platform`, a diferença de CPU por requisição fica entre 1,1× e 3×, conforme a proporção
entre listagens e agregações. A diferença de capacidade por pod é maior e vem da saturação por concorrência
descrita em 5.2.

#### 5.4 Memória

O Go fica entre 40 e 100 MB mesmo a 2.000 req/s. O Rails parte de ~170 MB depois do aquecimento e vai a ~260 MB,
bem abaixo do limite de 1 GB. Memória não foi gargalo para nenhuma das duas, mas o Rails pede de 2,5× a 5× mais
memória por pod, e isso aparece no *request* de memória do Kubernetes e na densidade de pods por nó.

#### 5.5 Capacidade e custo

Com o mesmo pod (2 CPUs, 1 GB), um pod Go sustentou pelo menos 2.000 req/s em todos os cenários. Um pod Rails
sustenta ~700–800 req/s nas rotas com upstream. Para o mesmo tráfego, o Rails precisaria de **~2,5× a 3× mais
pods**, ou de ajuste de threads ou servidor para usar melhor a CPU que sobra. Para converter isso em custo
mensal, cruze com o tráfego projetado do `/platform` e com o SLO de p99, quando a latência estiver medida.

### 6. Limitações e próximos passos

1. **Repetir a bateria com a latência medida.** Corrigir a permissão da pasta de resultados para o usuário do
   container k6 (por exemplo `chmod 777 results/<tag>` no `run.sh`, ou `user:` no serviço `k6` do
   `docker-compose.yml`) e parar de descartar a saída do k6, para que falhas como essa apareçam. Sem p95, p99 e
   erros, a decisão não fecha contra o SLO.
2. **Ambiente:** a rodada foi feita num notebook com WSL2, com k6, mock e middleware na mesma máquina. Para valer
   como referência, rodar numa máquina dedicada da mesma família de instância de produção, com o k6 em outro host.
3. **Repetições:** houve uma única execução. Rodar pelo menos 3 baterias e olhar a variação.
4. **Calibração:** ajustar `BASE_LATENCY_MS` e `JITTER_MS` para o p50 real dos serviços de domínio. Como o teto
   do Rails depende da latência do upstream (5.2), esse ajuste muda o resultado de forma relevante.
5. **Resiliência:** rodar o cenário com domínio lento e instável (`SLOW_RATE=0.1 ERROR_RATE=0.05`) e confirmar
   que o `show` continua com status 200 e latência perto de 300 ms nos casos degradados. No Rails, cada chamada
   lenta prende uma thread por até 300 ms, o que deve baixar o teto de concorrência ainda mais.
6. **Variações do Rails:** testar mais threads por processo e Falcon + async, para saber se o teto de
   concorrência é estrutural ou de configuração.
7. **Pod de produção:** repetir com o tamanho real de pod (por exemplo `MW_CPUS=1 MW_MEM=512m`).

### 7. Conclusão parcial

Nesta rodada, o Go entregou boot mais rápido, footprint muito menor, CPU por requisição entre igual (`list`) e
~3× menor (`show`), e, principalmente, **pelo menos 2,5× mais capacidade por pod**, porque não tem o teto de
concorrência que limitou o Rails a ~700–800 req/s. O Rails ficou competitivo na rota de transformação de JSON e
atende com folga cargas de até ~500 req/s por pod.

A conclusão ainda é parcial: falta medir latência (p95/p99) e erros, repetir em ambiente dedicado e rodar o
cenário de resiliência. Mesmo depois disso, a decisão deve pesar estes números junto com os critérios fora do
escopo do benchmark (seção 1).
