#!/usr/bin/env bash
# Garante que Go e Rails devolvem exatamente o mesmo JSON antes de comparar performance.
# Requer: jq, upstream + go + rails no ar (docker compose up -d upstream go rails),
# e o mock SEM falhas/lentidão (SLOW_RATE=0 ERROR_RATE=0).
set -euo pipefail
GO="${GO_URL:-http://localhost:8080}"
RAILS="${RAILS_URL:-http://localhost:3000}"

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

fail=0
for p in "${paths[@]}"; do
  a=$(curl -s -w '\n%{http_code}' "$GO$p");    sa=${a##*$'\n'}; ba=$(echo "${a%$'\n'*}" | jq -S .)
  b=$(curl -s -w '\n%{http_code}' "$RAILS$p"); sb=${b##*$'\n'}; bb=$(echo "${b%$'\n'*}" | jq -S .)
  if [[ "$sa" == "$sb" && "$ba" == "$bb" ]]; then
    echo "OK    $sa $p"
  else
    echo "DIFF  go=$sa rails=$sb $p"; diff <(echo "$ba") <(echo "$bb") | head -20; fail=1
  fi
done
exit $fail
