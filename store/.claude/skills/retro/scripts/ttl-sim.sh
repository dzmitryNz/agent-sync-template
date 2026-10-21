#!/usr/bin/env bash
# Replays main-thread requests and compares prompt-cache cost under 5m vs 1h TTL
# (API price ratios: write 1.25x / 2x, read 0.1x). Usage: ttl-sim.sh [since-date], default = retro last-run.
since=${1:-$(cat ~/.claude/skills/retro/last-run 2>/dev/null | cut -c1-10)}
since=${since:-$(date -d '-14 days' +%F)}
echo "window since $since"
find ~/.claude/projects -name '*.jsonl' -newermt "$since" -not -path '*/subagents/*' -print0 \
  | xargs -0 jq -r --arg since "$since" 'select(.type=="assistant" and .message.usage.cache_creation != null and (.isSidechain|not) and .timestamp >= $since)
      | [input_filename, (.timestamp|sub("\\.[0-9]+Z$";"Z")|fromdate),
         ((.message.usage.cache_read_input_tokens//0)+(.message.usage.cache_creation_input_tokens//0)),
         (.message.usage.cache_creation.ephemeral_5m_input_tokens//0), (.message.usage.cache_creation.ephemeral_1h_input_tokens//0)] | @tsv' 2>/dev/null \
  | sort -t$'\t' -k1,1 -k2,2n \
  | awk -F'\t' '
    {
      f=$1; t=$2; C=$3
      if ($4>0) w5++; if ($5>0) w1++
      if (f!=pf) { pf=f; pt=t; pc=C; c5+=C*1.25; c1+=C*2; n++; next }
      g=t-pt; d=C-pc; if (d<0) d=0
      if (g<=300) c5+=pc*0.1+d*1.25; else { c5+=C*1.25; miss5++ }
      if (g<=3600) c1+=pc*0.1+d*2; else { c1+=C*2; miss1++ }
      if (g<=60) b[1]++; else if (g<=300) b[2]++; else if (g<=600) b[3]++; else if (g<=1800) b[4]++; else if (g<=3600) b[5]++; else b[6]++
      pt=t; pc=C; n++
    }
    END {
      tot=b[1]+b[2]+b[3]+b[4]+b[5]+b[6]
      printf "requests=%d  actual cache writes: 5m=%d 1h=%d\n", n, w5, w1
      split("<=1m 1-5m 5-10m 10-30m 30-60m >60m", L, " ")
      for (i=1;i<=6;i++) printf "  gap %-7s %6d  %5.1f%%\n", L[i], b[i], 100*b[i]/tot
      printf "full rebuilds: 5m TTL=%d  1h TTL=%d\n", miss5, miss1
      printf "cost (Mtok-equiv of base input): 5m=%.0f  1h=%.0f  ratio 1h/5m=%.2f\n", c5/1e6, c1/1e6, c1/c5
    }'
