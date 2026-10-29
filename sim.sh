#!/usr/bin/env bash
# ./sim.sh [tb_or_entity] [stop_time]
shopt -s nullglob
cd "$(dirname "$0")"

arg=${1:-}
if   [[ -n $arg && -f tb/$arg.vhd ]];    then TOP=$arg
elif [[ -n $arg && -f tb/tb_$arg.vhd ]]; then TOP=tb_$arg
else
  tbs=(tb/*.vhd)
  [[ ${#tbs[@]} -gt 0 ]] || { echo "no testbench in tb/"; exit 1; }
  TOP=$(basename "${tbs[0]}" .vhd)
fi
STOP=${2:-100us}
WAVE=build/$TOP.fst
NVC=(nvc --std=2008 --work=work:build/work)

rm -rf build/work
mkdir -p build

# analyse until no progress (auto file order)
pending=(src/*.vhd src/*.vhdl tb/*.vhd tb/*.vhdl)
while [[ ${#pending[@]} -gt 0 ]]; do
  left=()
  for f in "${pending[@]}"; do
    "${NVC[@]}" -a "$f" >/dev/null 2>&1 || left+=("$f")
  done
  if [[ ${#left[@]} -eq ${#pending[@]} ]]; then
    for f in "${left[@]}"; do "${NVC[@]}" -a "$f"; done
    exit 1
  fi
  pending=("${left[@]}")
done

echo "sim: $TOP"
"${NVC[@]}" -e "$TOP" -r --stop-time="$STOP" --wave="$WAVE" || exit 1
echo "wave: $WAVE"
if command -v code >/dev/null; then code -r "$WAVE"; fi
