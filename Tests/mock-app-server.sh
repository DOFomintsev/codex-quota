#!/bin/zsh
set -euo pipefail

# Local test server: no Codex, network, credentials or conversation data.
reads=0
initialized=false
while IFS= read -r line; do
    case "$line" in
        *'"method":"initialize"'*)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
        *'"method":"initialized"'*) initialized=true ;;
        *rateLimits*)
            [[ "$initialized" == true ]]
            request_id=$(printf '%s' "$line" | /usr/bin/plutil -extract id raw -o - -)
            reads=$((reads + 1))
            used=$((20 + reads * 20))
            printf '{"id":%s,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":%s,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1900500000}}}}}\n' "$request_id" "$used"
            if [[ "$reads" == 1 ]]; then
                # Split a notification into chunks to exercise streaming framing.
                printf '%s' '{"method":"account/rateLimits/updated","params":'
                printf '%s\n' '{"rateLimits":{"limitId":"codex","primary":{"usedPercent":50}}}}'
            else
                # Give the client time to process the final response before EOF.
                sleep 0.2
                exit 0
            fi
            ;;
    esac
done
