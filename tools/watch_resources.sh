#!/bin/bash
# Claude Pet のリソース使用量を定期記録する（長時間稼働の観測用）
# 使い方: ./tools/watch_resources.sh [間隔秒=60] [出力=/tmp/clawn_resources.csv]
# 出力: time,pid,rss_kb,cpu_pct,threads の CSV。プロセス不在の行は pid 以降が空。
set -u
INTERVAL=${1:-60}
OUT=${2:-/tmp/clawn_resources.csv}

[ -f "$OUT" ] || echo "time,pid,rss_kb,cpu_pct,threads" > "$OUT"
echo "recording to $OUT every ${INTERVAL}s (Ctrl-C で終了)"

while true; do
  PID=$(pgrep -f '/Applications/ClaudePet.app' | head -1)
  if [ -n "$PID" ]; then
    RSS_CPU=$(ps -o rss=,%cpu= -p "$PID" | awk '{print $1","$2}')
    THREADS=$(ps -M -p "$PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo "$(date +%FT%T),$PID,$RSS_CPU,$THREADS" >> "$OUT"
  else
    echo "$(date +%FT%T),,,," >> "$OUT"
  fi
  sleep "$INTERVAL"
done
