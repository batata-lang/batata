#!/usr/bin/env bash
set -euo pipefail

report_dir="${1:-_build/tsan}"
iterations="${2:-1}"
seeds="${3:-0x6201}"

if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "iterations must be a positive integer" >&2
  exit 2
fi

mkdir -p "$report_dir"
binary="$report_dir/term-runtime-tsan"
compile_log="$report_dir/compile.log"
summary="$report_dir/summary.txt"

zig_version="$(zig version)"
compile_flags="-lc -fllvm -fsanitize-thread -fno-omit-frame-pointer"

printf 'zig_version=%s\ncompile_flags=%s\niterations=%s\nseeds=%s\nsuppressions=none\n' \
  "$zig_version" "$compile_flags" "$iterations" "$seeds" >"$summary"

echo "tsan build: zig=$zig_version flags=$compile_flags"
zig test native/term_runtime.zig \
  -lc \
  -fllvm \
  -fsanitize-thread \
  -fno-omit-frame-pointer \
  --test-no-exec \
  -femit-bin="$binary" 2>&1 | tee "$compile_log"

# Zig 0.16 accepts -fsanitize-thread with its self-hosted backend without
# instrumenting the output. Require the LLVM backend above and independently
# verify the linked runtime so this gate can never degrade to an ordinary run.
nm -an "$binary" >"$report_dir/symbols.txt"
if ! grep -qE '[[:space:]]__tsan_init$' "$report_dir/symbols.txt"; then
  echo "error: $binary is not linked with ThreadSanitizer" | tee -a "$summary" >&2
  exit 3
fi

echo "instrumentation=verified" >>"$summary"
IFS=',' read -r -a seed_list <<<"$seeds"

run_index=0
for seed in "${seed_list[@]}"; do
  seed="${seed//[[:space:]]/}"
  if [[ -z "$seed" ]]; then
    echo "seed list contains an empty entry" >&2
    exit 2
  fi
  for ((iteration = 1; iteration <= iterations; iteration += 1)); do
    run_index=$((run_index + 1))
    log="$report_dir/run-${run_index}-${seed}.log"
    echo "tsan run: seed=$seed iteration=$iteration case=native-concurrency-suite"
    if ! timeout --signal=TERM --kill-after=15s 180s \
      env BATATA_TSAN_SEED="$seed" \
      TSAN_OPTIONS="halt_on_error=1:exitcode=66:history_size=7:second_deadlock_stack=1:symbolize=1" \
      "$binary" 2>&1 | tee "$log"; then
      printf 'status=failed\nfailed_seed=%s\nfailed_iteration=%s\nfailed_log=%s\n' \
        "$seed" "$iteration" "$log" >>"$summary"
      exit 1
    fi
  done
done

printf 'status=passed\nruns=%s\n' "$run_index" >>"$summary"
echo "tsan summary: status=passed runs=$run_index report=$report_dir"
