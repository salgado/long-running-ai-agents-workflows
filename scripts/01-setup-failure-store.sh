#!/bin/bash
# =============================================================================
# Script 01: Failure Store Setup
#
# What it does:
#   1. Deletes the existing data stream and index template (if they exist)
#   2. Creates an index template with failure store enabled
#   3. Ingests 3 valid documents (indexed normally into the data stream)
#   4. Initializes the failure store index (creates and immediately deletes
#      one invalid document so the @timestamp field is available in Kibana
#      when configuring the alerting rule)
#
# Use 02-trigger-test.sh to ingest invalid documents, which triggers the
# alerting rule and starts the remediation workflow.
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

ES_URL="${ES_URL:?Set ES_URL environment variable}"
ES_API_KEY="${ES_API_KEY:?Set ES_API_KEY environment variable}"

AUTH="Authorization: ApiKey ${ES_API_KEY}"
CT="Content-Type: application/json"

echo "============================================"
echo "  Failure Store Setup"
echo "============================================"
echo ""

# --- Step 1: Clean up previous environment ---
echo "[1/3] Cleaning up previous environment..."
curl -s -X DELETE "${ES_URL}/_data_stream/logs-demo-app" \
  -H "${AUTH}" > /dev/null 2>&1 || true
curl -s -X DELETE "${ES_URL}/_index_template/logs-demo-app-template" \
  -H "${AUTH}" > /dev/null 2>&1 || true
echo "  Done"
echo ""

# --- Step 2: Create index template with failure store ---
echo "[2/3] Creating index template with failure store enabled..."
curl -sS -f -X PUT "${ES_URL}/_index_template/logs-demo-app-template" \
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
  }' > /dev/null
echo "  Done"
echo ""

# --- Step 3: Ingest valid documents ---
echo "[3/4] Ingesting 3 valid documents (price as float)..."
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
curl -sS -f -X POST "${ES_URL}/_bulk" \
  -H "${AUTH}" \
  -H "Content-Type: application/x-ndjson" \
  -d "{\"create\":{\"_index\":\"logs-demo-app\"}}
{\"@timestamp\":\"${NOW}\",\"message\":\"Order completed\",\"price\":49.99,\"status\":\"completed\",\"user_id\":\"u-1001\",\"category\":\"electronics\"}
{\"create\":{\"_index\":\"logs-demo-app\"}}
{\"@timestamp\":\"${NOW}\",\"message\":\"Order shipped\",\"price\":29.99,\"status\":\"shipped\",\"user_id\":\"u-1002\",\"category\":\"books\"}
{\"create\":{\"_index\":\"logs-demo-app\"}}
{\"@timestamp\":\"${NOW}\",\"message\":\"Order placed\",\"price\":149.99,\"status\":\"placed\",\"user_id\":\"u-1003\",\"category\":\"electronics\"}
" | python3 -c "
import sys,json
data = json.load(sys.stdin)
ok = sum(1 for i in data['items'] if i['create'].get('failure_store','none')=='none')
print(f'  {ok} docs indexed into data stream')
"
echo ""

# --- Step 4: Initialize failure store and delete the init document ---
echo "[4/4] Initializing failure store (creates the index, then removes the init document)..."
BULK_RESPONSE=$(curl -sS -f -X POST "${ES_URL}/_bulk" \
  -H "${AUTH}" \
  -H "Content-Type: application/x-ndjson" \
  -d "{\"create\":{\"_index\":\"logs-demo-app\"}}
{\"@timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"message\":\"init\",\"price\":\"SETUP\",\"status\":\"init\",\"user_id\":\"u-setup-init\",\"category\":\"setup\"}
")

# Extract the backing index and document ID from the bulk response
FS_INDEX=$(echo "$BULK_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    c = item.get('create', {})
    if c.get('failure_store') == 'used':
        print(c.get('_index', ''))
        break
")
FS_ID=$(echo "$BULK_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    c = item.get('create', {})
    if c.get('failure_store') == 'used':
        print(c.get('_id', ''))
        break
")

if [[ -n "$FS_INDEX" && -n "$FS_ID" ]]; then
  curl -sS -f -X DELETE "${ES_URL}/${FS_INDEX}/_doc/${FS_ID}?refresh=true" \
    -H "${AUTH}" > /dev/null
  echo "  Failure store initialized and init document deleted"
else
  echo "  Warning: could not locate init document in failure store — check manually"
fi
echo ""

echo "============================================"
echo "  Setup complete!"
echo ""
echo "  State:"
echo "    logs-demo-app           → 3 valid documents"
echo "    logs-demo-app::failures → 0 documents (empty, index initialized)"
echo ""
echo "  Next steps:"
echo "    1. Run restore.py to import agents, skills, and workflow"
echo "    2. Create the alerting rule in Kibana"
echo "    3. Connect the rule to the failure_store_remediation workflow"
echo "    4. Run 02-trigger-test.sh to ingest invalid documents and start the workflow"
echo "============================================"
