#!/bin/bash
# Action: clear a stale bootstrap status ($setup token) on the focused workspace.
set -u
herdr="${HERDR_BIN_PATH:-herdr}"
ws=$(jq -r '.workspace_id // empty' <<< "${HERDR_PLUGIN_CONTEXT_JSON:-null}"); [ -n "$ws" ] || ws="${HERDR_WORKSPACE_ID:?no workspace}"
"$herdr" workspace report-metadata "$ws" --source stu-bootstrap --clear-token setup >/dev/null
