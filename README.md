# Long-running AI agents with Elasticsearch Workflows

Code companion for the Elasticsearch Labs blog post: [Long-running AI agents with Elasticsearch Workflows: pause for human approval, resume days later](#).

## What this builds

A workflow that remediates failed documents in an Elasticsearch failure store using AI agents and human approval gates:

1. An alerting rule detects failures in the failure store
2. An AI agent (`failure-analyst`) diagnoses the root cause and proposes a fix
3. The workflow pauses for engineer approval (days if needed, zero compute cost)
4. If approved, the workflow pauses again at Gate 2 — the engineer opens the `remediation-executor` agent, types "run remediation", and the `execute-failure-store-fix` skill reads the approved diagnosis from `remediation-runs`, creates the ingest pipeline, and runs the reindex automatically
5. The engineer verifies the results and marks the case as resolved or escalated

## Prerequisites

- An Elastic Cloud Serverless project (Elasticsearch/Search type)
- Agent Builder (GA, enabled by default on Search projects)
- Workflows enabled (technical preview; enable in Management → Feature Settings)

## Setup

### 1. Configure environment variables

```bash
export ES_URL="https://your-project.es.region.gcp.elastic.cloud:443"
export ES_API_KEY="your-api-key"
```

### 2. Create the data stream with failure store

```bash
./scripts/01-setup-failure-store.sh
```

This creates the `logs-demo-app` data stream with failure store enabled, ingests valid documents and documents with invalid `price` values that get redirected to the failure store.

### 3. Create the AI agents

Create two agents in Agent Builder (Kibana):

**failure-analyst** — Analyzes failed documents and proposes remediation.
- Custom instructions: see `agents/failure-analyst-instructions.txt`
- Tools: none required (receives data via prompt)

**remediation-executor** — Reads the approved diagnosis and executes the fix.
- Custom instructions: see `agents/remediation-executor-instructions.txt`
- Tools: enable built-in capabilities; ensure `platform.core.search` is active
- Skills: create the `execute-failure-store-fix` skill with the instructions below:

```
When asked to run a remediation, execute a fix, or remediate failures:

1. Search the remediation-runs index for the most recent document with status
   "awaiting_fix_approval". Use the query:
   {"query": {"term": {"status": "awaiting_fix_approval"}},
    "sort": [{"_doc": "desc"}], "size": 1}

2. From the diagnosis field, extract the remediation_pipeline definition
   (pipeline name and processors).

3. Create the ingest pipeline in Elasticsearch using the extracted definition.

4. Run a reindex from the failure store index specified in the diagnosis
   to logs-demo-app, using the pipeline you just created.

5. Report the results: how many documents were matched, successfully
   reindexed, and how many failed.
```

### 4. Import the workflow

In Kibana, go to **Workflows** and import `workflow/failure-store-remediation.yaml`.

### 5. Create the alerting rule

In Kibana, go to **Management → Rules → Create rule → Elasticsearch query**:

- Query type: ES|QL
- Query:
  ```sql
  FROM logs-demo-app::failures
  | WHERE @timestamp > NOW() - 5 minutes
  | STATS failure_count = COUNT(*)
  | WHERE failure_count > 0
  ```
- Check every: 1 minute
- Actions: Add action → Workflows → select `failure_store_remediation`
- (Optional) Add action → Email → configure notification

### 6. Test

Ingest documents with invalid prices to trigger the alert:

```bash
./scripts/02-trigger-test.sh
```

Then watch Workflows → Executions for the workflow to start.

## How it works

When the workflow reaches Gate 2, the engineer:

1. Opens the `remediation-executor` agent in Agent Builder
2. Types "run remediation"
3. The `execute-failure-store-fix` skill automatically:
   - Fetches the latest approved diagnosis from `remediation-runs`
   - Creates the ingest pipeline
   - Runs the reindex from the failure store to `logs-demo-app`
   - Reports how many documents were matched, reindexed, and failed
4. The engineer verifies results in Dev Tools and confirms in the workflow

## Files

```
├── README.md
├── workflow/
│   └── failure-store-remediation.yaml   # The complete workflow YAML
├── scripts/
│   ├── 01-setup-failure-store.sh        # Creates data stream + ingests test data
│   └── 02-trigger-test.sh              # Ingests bad docs to trigger the alert
└── agents/
    ├── failure-analyst-instructions.txt
    └── remediation-executor-instructions.txt
```

## Related

- [Blog post: Long-running AI agents with Elasticsearch Workflows](#)
- [Elasticsearch Workflows documentation](https://www.elastic.co/docs/explore-analyze/workflows)
- [Agent Builder documentation](https://www.elastic.co/docs/explore-analyze/ai-features/agent-builder)
- [Failure store documentation](https://www.elastic.co/docs/manage-data/data-store/data-streams/failure-store)
