#!/bin/sh
set -eu

while IFS= read -r request; do
  id=$(printf '%s' "$request" | sed -E 's/.*"id":([0-9]+).*/\1/')
  case "$request" in
    *'"method":"initialize"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
      ;;
    *'"method":"account/rateLimits/read"'*)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":12,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":34,\"windowDurationMins\":10080}}}}"
      ;;
    *'"method":"thread/list"'*)
      case "$request" in
        *'"sortKey":"updated_at"'*)
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"data\":[{\"id\":\"fixture-thread\",\"name\":\"Fixture conversation\",\"cwd\":\"/tmp/project\",\"sourceKind\":\"cli\",\"status\":{\"type\":\"idle\"}}],\"nextCursor\":null}}"
          ;;
        *) printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32602,\"message\":\"invalid sort key\"}}" ;;
      esac
      ;;
    *'"method":"thread/read"'*)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"thread\":{\"status\":{\"type\":\"idle\"},\"turns\":[{\"id\":\"fixture-turn\",\"status\":\"failed\",\"error\":{\"codexErrorInfo\":{\"type\":\"UsageLimitExceeded\"},\"message\":\"fixture limit\"}}]}}}"
      ;;
    *'"method":"thread/resume"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
      ;;
    *'"method":"turn/start"'*)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"turn":{"id":"fixture-resumed-turn","status":"inProgress"}}}\n' "$id"
      printf '%s\n' '{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"fixture-thread","turn":{"id":"fixture-resumed-turn","status":"completed"}}}'
      ;;
    *'"method":"initialized"'*) : ;;
    *)
      printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"unexpected fake method\"}}"
      ;;
  esac
done
