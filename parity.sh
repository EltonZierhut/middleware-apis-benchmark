#!/usr/bin/env bash
# Garante que Go, Rails e Node devolvem exatamente o mesmo JSON antes de comparar performance.
# O Go é a referência; cada implementação em IMPLS é comparada com ele.
# Requer: jq, upstream + implementações no ar (docker compose up -d upstream go rails node),
# e o mock SEM falhas/lentidão (SLOW_RATE=0 ERROR_RATE=0).
#
# Uso:
#   ./parity.sh                 # compara rails e node com go
#   IMPLS="node" ./parity.sh    # só node
set -euo pipefail
declare -A URL=(
  [go]="${GO_URL:-http://localhost:8080}"
  [rails]="${RAILS_URL:-http://localhost:3000}"
  [node]="${NODE_URL:-http://localhost:3001}"
)
IMPLS="${IMPLS:-rails node}"

paths=(
  "/health"
  "/platform/contacts"
  "/platform/contacts?page=3&page_size=10"
  "/platform/contacts?page=2&page_size=100&filter%5Blead_stage%5D=qualified_lead"
  "/platform/contacts?page=1&filter%5Btag%5D=saas"
  "/platform/contacts?page=4&filter%5Bemail_domain%5D=empresa.com.br"
  "/platform/contacts?page=999"
  "/platform/contacts?page_size=0"
  "/platform/contacts/c-000001"
  "/platform/contacts/c-004321"
  "/platform/contacts/nao-existe"
)

# imprime "<status>\n<json normalizado>"
fetch() {
  local r; r=$(curl -s -w '\n%{http_code}' "$1")
  echo "${r##*$'\n'}"; echo "${r%$'\n'*}" | jq -S .
}

fail=0
for p in "${paths[@]}"; do
  ref=$(fetch "${URL[go]}$p"); sref=${ref%%$'\n'*}
  for impl in $IMPLS; do
    got=$(fetch "${URL[$impl]}$p"); sgot=${got%%$'\n'*}
    if [[ "$ref" == "$got" ]]; then
      printf 'OK    %-6s %s %s\n' "$impl" "$sgot" "$p"
    else
      printf 'DIFF  %-6s go=%s %s=%s %s\n' "$impl" "$sref" "$impl" "$sgot" "$p"
      diff <(echo "$ref") <(echo "$got") | head -20; fail=1
    fi
  done
done
exit $fail
