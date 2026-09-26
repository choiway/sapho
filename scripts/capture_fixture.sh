#!/usr/bin/env bash
set -euo pipefail
# Manual debugging only. Live responses may contain account-linked metadata and
# encrypted reasoning; never commit them. Checked-in fixtures are synthetic.
# Request shape: openai/codex e72da2b53805894878023d01949a25a082e0a5cb
# codex-rs/core/src/client.rs (ResponsesApiRequest), codex-rs/core/src/client_tests.rs
# and codex-rs/codex-api/src/endpoint/responses.rs.
cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo 'jq required' >&2; exit 1; }
auth="${CODEX_HOME:-$HOME/.codex}/auth.json"
if [[ ! -f "$auth" ]]; then echo 'codex login required (missing auth.json)' >&2; exit 1; fi
# Never print credentials or pass them in process arguments.
expiry=$(jq -r '.tokens.access_token | split(".")[1] | @base64d | fromjson | .exp // 0' "$auth" 2>/dev/null) || expiry=0
if [[ $(jq -r '.auth_mode' "$auth") != chatgpt || $expiry -le $(date +%s) ]]; then
  echo 'codex login required (expired or unsupported auth)' >&2; exit 1
fi
# Keep captures out of the tracked test fixture directory, regardless of cwd.
umask 077
output_dir=.local-fixtures/sse
mkdir -p "$output_dir"
body=$(mktemp)
response=$(mktemp)
trap 'rm -f "$body" "$response"' EXIT
names=("${@}")
if (( ${#names[@]} == 0 )); then names=(text_only reasoning_tool multibyte); fi
for name in "${names[@]}"; do
  case "$name" in
    text_only) prompt='Reply with exactly: hello world'; effort=low ;;
    reasoning_tool) prompt='Think through which city is the capital of Japan and why, then call get_weather with that city. Do not answer without calling the tool.'; effort=medium ;;
    multibyte) prompt='Reply with exactly: 日本語 🎉 é — ok'; effort=low ;;
    *) echo "Unknown fixture name: $name" >&2; exit 1 ;;
  esac
  jq -n --arg prompt "$prompt" --arg effort "$effort" --arg name "$name" '{
    model:"gpt-5.6-sol", instructions:"Follow the user request precisely.",
    input:[{role:"user",content:$prompt}], store:false, stream:true,
    include:["reasoning.encrypted_content"], reasoning:{effort:$effort,summary:"auto"},
    tools:(if $name == "reasoning_tool" then [{type:"function",name:"get_weather",description:"Get weather for a city",parameters:{type:"object",properties:{city:{type:"string"}},required:["city"],additionalProperties:false},strict:true}] else [] end),
    tool_choice:"auto"
  }' > "$body"
  # curl config is supplied on stdin, not argv (which is visible in /proc).
  # jq @json quotes values for curl's config grammar.
  jq -r '
    "header = " + ("Authorization: Bearer " + .tokens.access_token | @json),
    "header = " + ("chatgpt-account-id: " + .tokens.account_id | @json),
    "header = \"Content-Type: application/json\"",
    "header = \"Accept: text/event-stream\""
  ' "$auth" | curl --silent --show-error --fail-with-body --no-buffer -K - \
    --data-binary "@$body" -o "$response" \
    'https://chatgpt.com/backend-api/codex/responses'
  if ! grep -q 'event: response.completed' "$response"; then
    echo "Incomplete stream for $name; not replacing fixture" >&2; exit 1
  fi
  cp "$response" "$output_dir/$name.sse"
done
echo "Live captures saved in $output_dir (ignored by git). Do not commit them." >&2
