#!/usr/bin/env bash
set -u
plugin=${1:-}
tag=$2
wt=/home/onyx/.no-mistakes/worktrees/e7f71fdfbe8f/01M5XN6RHB365J3Q9YF6V1KQCR
PI_PACKAGE_DIR=${PI_PACKAGE_DIR:-/home/onyx/code/pi/packages/coding-agent}
root=$(mktemp -d /tmp/fm-live-probe/$tag.XXXXXX) || exit 1
mkdir -p "$root/agent-dir"
cat > "$root/agent-dir/models.json" <<'JSON'
{
  "providers": {
    "fm-live-probe": {
      "baseUrl": "https://fm-live-probe.invalid/v1",
      "api": "openai-completions",
      "apiKey": "fm-live-placeholder",
      "models": [
        { "id": "fm-live-probe-model", "name": "fm live probe", "contextWindow": 8192, "maxTokens": 512 }
      ]
    }
  }
}
JSON
PLUGIN="$plugin" \
FM_HOME="$root/home" FM_ROOT_OVERRIDE="$wt" FM_WORK="$root" \
PI_CODING_AGENT_DIR="$root/agent-dir" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
NODE_NO_WARNINGS=1 \
node /tmp/fm-live-probe/probe.mjs
status=$?
echo "--- probe exit=$status root=$root"
