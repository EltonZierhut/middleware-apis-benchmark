// Teste de carga com taxa de chegada constante (open model): a taxa não cai quando
// o servidor fica lento, então latência e erros aparecem de verdade.
//
// Variáveis:
//   TARGET    URL base (ex.: http://go:8080)
//   SCENARIO  list | show | mixed | health
//   RATE      requisições por segundo
//   DURATION  ex.: 60s
//   OUT       caminho do JSON de resumo
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET;
const SCENARIO = __ENV.SCENARIO || 'mixed';
const RATE = parseInt(__ENV.RATE || '200', 10);
const DURATION = __ENV.DURATION || '60s';

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(50, Math.ceil(RATE * 0.5)),
      maxVUs: Math.max(200, RATE * 3),
    },
  },
};

const filters = [
  '',
  '&filter[lead_stage]=lead',
  '&filter[tag]=saas',
  '&filter[email_domain]=empresa.com.br',
];

function listReq() {
  const page = 1 + Math.floor(Math.random() * 50);
  const f = filters[Math.floor(Math.random() * filters.length)];
  return http.get(`${TARGET}/platform/contacts?page=${page}&page_size=25${f}`, { tags: { name: 'list' } });
}

function showReq() {
  const id = 'c-' + String(1 + Math.floor(Math.random() * 5000)).padStart(6, '0');
  return http.get(`${TARGET}/platform/contacts/${id}`, { tags: { name: 'show' } });
}

export default function () {
  let res;
  switch (SCENARIO) {
    case 'health': res = http.get(`${TARGET}/health`, { tags: { name: 'health' } }); break;
    case 'list': res = listReq(); break;
    case 'show': res = showReq(); break;
    default: res = Math.random() < 0.7 ? listReq() : showReq();
  }
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const out = __ENV.OUT || '/results/summary.json';
  return { [out]: JSON.stringify(data, null, 2) };
}
