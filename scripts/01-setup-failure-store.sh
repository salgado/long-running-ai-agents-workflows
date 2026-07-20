#!/bin/bash
# =============================================================================
# Script 01: Failure Store Setup
#
# What it does:
#   1. Creates an index template with failure store enabled
#   2. Ingests valid documents (indexed into the data stream)
#   3. Ingests invalid documents (redirected to the failure store)
#   4. Verifies the count in each
#
# Prerequisites:
#   - Elastic Cloud Serverless project running
#   - ES_URL and ES_API_KEY environment variables set
#
# Key concepts:
#   - Data Stream: append-only structure optimized for time-series data
#   - Failure Store: secondary index within the data stream that captures
#     documents that failed during ingestion (instead of losing them)
#   - ignore_malformed: false forces the error (without it, ES silences the field)
#   - ::failures syntax to access a data stream's failure store
# =============================================================================

set -euo pipefail

# --- Configuration ---
ES_URL="${ES_URL:?Set ES_URL environment variable}"
ES_API_KEY="${ES_API_KEY:?Set ES_API_KEY environment variable}"

# Common headers
AUTH="Authorization: ApiKey ${ES_API_KEY}"
CT="Content-Type: application/json"

echo "============================================"
echo "  Failure Store Setup"
echo "============================================"
echo ""

# --- Step 1: Clean up previous environment (if exists) ---
echo "[1/5] Cleaning up previous environment..."
curl -s -X DELETE "${ES_URL}/_data_stream/logs-demo-app" \
  -H "${AUTH}" > /dev/null 2>&1 || true
curl -s -X DELETE "${ES_URL}/_index_template/logs-demo-app-template" \
  -H "${AUTH}" > /dev/null 2>&1 || true
echo "  Done"
echo ""

# --- Step 2: Create index template with failure store ---
echo "[2/5] Creating index template with failure store enabled..."
curl -s -X PUT "${ES_URL}/_index_template/logs-demo-app-template" \
  -H "${AUTH}" \
  -H "${CT}" \
  -d '{
    "index_patterns": ["logs-demo-app"],
    "data_stream": {},
    "priority": 500,
    "template": {
      "mappings": {
        "properties": {
          "@timestamp": { "type": "date" },
          "message":    { "type": "text" },
          "price":      { "type": "float", "ignore_malformed": false },
          "status":     { "type": "keyword" },
          "user_id":    { "type": "keyword" },
          "category":   { "type": "keyword" }
        }
      },
      "data_stream_options": {
        "failure_store": {
          "enabled": true
        }
      }
    }
  }' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  acknowledged: {d.get(\"acknowledged\",False)}')"
echo ""

# --- Step 3: Ingest valid documents ---
echo "[3/5] Ingesting 3 valid documents (price as float)..."
curl -s -X POST "${ES_URL}/_bulk" \
  -H "${AUTH}" \
  -H "Content-Type: application/x-ndjson" \
  -d '{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:00:00Z","message":"Order completed","price":49.99,"status":"completed","user_id":"u-1001","category":"electronics"}
{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:01:00Z","message":"Order shipped","price":29.99,"status":"shipped","user_id":"u-1002","category":"books"}
{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:02:00Z","message":"Order placed","price":149.99,"status":"placed","user_id":"u-1003","category":"electronics"}
' | python3 -c "
import sys,json
data = json.load(sys.stdin)
ok = sum(1 for i in data['items'] if i['create'].get('failure_store','none')=='none')
print(f'  {ok} docs indexed into data stream')"
echo ""

# --- Step 4: Ingest invalid documents ---
echo "[4/5] Ingesting 5 invalid documents (price as string)..."
echo "  These should be redirected to the failure store."
curl -s -X POST "${ES_URL}/_bulk" \
  -H "${AUTH}" \
  -H "Content-Type: application/x-ndjson" \
  -d '{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:05:00Z","message":"Order pending","price":"N/A","status":"pending","user_id":"u-1006","category":"electronics"}
{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:06:00Z","message":"Free trial started","price":"free","status":"trial","user_id":"u-1007","category":"software"}
{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:07:00Z","message":"Refund pending","price":"TBD","status":"refund","user_id":"u-1008","category":"electronics"}
{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:08:00Z","message":"Gift order","price":"complimentary","status":"gift","user_id":"u-1009","category":"accessories"}
{"create":{"_index":"logs-demo-app"}}
{"@timestamp":"2026-07-01T10:09:00Z","message":"Bulk discount","price":"varies","status":"bulk","user_id":"u-1010","category":"wholesale"}
' | python3 -c "
import sys,json
data = json.load(sys.stdin)
fs = sum(1 for i in data['items'] if i['create'].get('failure_store','')=='used')
print(f'  {fs} docs redirected to failure store')"
echo ""

# --- Step 5: Verify ---
echo "[5/5] Verifying..."

echo ""
echo "  Data stream (valid docs):"
curl -s "${ES_URL}/logs-demo-app/_count" \
  -H "${AUTH}" | python3 -c "import sys,json; print(f'    count: {json.load(sys.stdin)[\"count\"]}')"

echo ""
echo "  Failure store (invalid docs):"
# Refresh to ensure near-real-time visibility
curl -s -X POST "${ES_URL}/logs-demo-app::failures/_refresh" \
  -H "${AUTH}" > /dev/null 2>&1

curl -s "${ES_URL}/logs-demo-app::failures/_count" \
  -H "${AUTH}" | python3 -c "import sys,json; print(f'    count: {json.load(sys.stdin)[\"count\"]}')"

echo ""
echo "  Sample failure store document:"
curl -s "${ES_URL}/logs-demo-app::failures/_search?size=1" \
  -H "${AUTH}" \
  -H "${CT}" \
  -d '{"_source":["document.source.price","document.source.message","error.type","error.message"]}' | python3 -c "
import sys,json
hit = json.load(sys.stdin)['hits']['hits'][0]['_source']
doc = hit.get('document',{}).get('source',{})
err = hit.get('error',{})
print(f'    doc.price:     {doc.get(\"price\",\"?\")}')
print(f'    doc.message:   {doc.get(\"message\",\"?\")}')
print(f'    error.type:    {err.get(\"type\",\"?\")}')
print(f'    error.message: {err.get(\"message\",\"?\")[:80]}...')
"

echo ""
echo "============================================"
echo "  Setup complete!"
echo ""
echo "  Next step: create the AI agents in"
echo "  Agent Builder (Kibana)"
echo "============================================"
