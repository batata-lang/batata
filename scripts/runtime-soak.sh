#!/usr/bin/env bash
set -uo pipefail

report_dir="${1:-_build/runtime_soak}"
scale="${2:-1}"
seeds="${3:-0x6101}"

mkdir -p "$report_dir"
summary="$report_dir/report.json"
failed=0
first=1

printf '{\n  "scale": %s,\n  "runs": [\n' "$scale" >"$summary"

IFS=',' read -r -a seed_list <<<"$seeds"
for seed in "${seed_list[@]}"; do
  log="$report_dir/seed-${seed}.log"
  started="$(date +%s)"
  printf 'runtime soak: seed=%s scale=%s\n' "$seed" "$scale" >"$log"

  if timeout --signal=TERM 600s env \
    BATATA_SOAK_SEED="$seed" BATATA_SOAK_SCALE="$scale" \
    zig test --dep runtime \
      -Mroot=native/runtime_soak_test.zig \
      -Mruntime=native/term_runtime.zig \
      -lc >>"$log" 2>&1; then
    status="passed"
  else
    code="$?"
    if [ "$code" -eq 124 ]; then
      status="timeout"
    else
      status="failed"
    fi
    failed=1
  fi

  cat "$log"
  elapsed="$(( $(date +%s) - started ))"
  if [ "$first" -eq 0 ]; then
    printf ',\n' >>"$summary"
  fi
  first=0
  printf '    {"seed": "%s", "status": "%s", "elapsed_seconds": %s}' \
    "$seed" "$status" "$elapsed" >>"$summary"
done

printf '\n  ]\n}\n' >>"$summary"
cat "$summary"
exit "$failed"
