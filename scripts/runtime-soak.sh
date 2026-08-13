#!/usr/bin/env bash
set -uo pipefail

report_dir="${1:-_build/runtime_soak}"
scale="${2:-1}"
seeds="${3:-0x6101}"

if [[ ! "$scale" =~ ^[1-9][0-9]*$ ]]; then
  echo "scale must be a positive integer" >&2
  exit 2
fi

mkdir -p "$report_dir"
summary="$report_dir/report.json"
failed=0
first=1

zig_version="$(zig version)"
printf '{\n  "schema_version": 2,\n  "test_identity": "native/runtime_soak_test.zig",\n  "zig_version": "%s",\n  "scale": %s,\n  "runs": [\n' \
  "$zig_version" "$scale" >"$summary"

IFS=',' read -r -a seed_list <<<"$seeds"
for seed in "${seed_list[@]}"; do
  seed="${seed//[[:space:]]/}"
  if [[ ! "$seed" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
    echo "invalid replay seed: $seed" >&2
    exit 2
  fi

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
    code=0
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
  log_sha256="$(sha256sum "$log" | awk '{print $1}')"
  fingerprint="$(printf 'seed=%s\nscale=%s\nstatus=%s\nexit=%s\nlog=%s\n' \
    "$seed" "$scale" "$status" "$code" "$log_sha256" | sha256sum | awk '{print $1}')"
  elapsed="$(( $(date +%s) - started ))"
  if [ "$first" -eq 0 ]; then
    printf ',\n' >>"$summary"
  fi
  first=0
  printf '    {"seed": "%s", "status": "%s", "exit_code": %s, "elapsed_seconds": %s, "log_sha256": "%s", "artifact_fingerprint": "%s", "replay_env": {"BATATA_SOAK_SEED": "%s", "BATATA_SOAK_SCALE": "%s"}}' \
    "$seed" "$status" "$code" "$elapsed" "$log_sha256" "$fingerprint" "$seed" "$scale" >>"$summary"
done

printf '\n  ]\n}\n' >>"$summary"
cat "$summary"
exit "$failed"
