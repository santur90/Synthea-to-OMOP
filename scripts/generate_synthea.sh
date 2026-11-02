#!/usr/bin/env bash
# Run Synthea (CSV export only) using settings from config/config.yml.
# Env overrides: SYNTHEA_POP, SYNTHEA_SEED, SYNTHEA_STATE.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=config/config.yml

# Read "key: value" from the top-level `synthea:` block of the config.
cfg() {
  awk -v k="$1" '
    /^[^[:space:]#]/ { in_blk = ($1 == "synthea:") ; next }
    in_blk && $1 == k":" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit }
  ' "$CONFIG"
}

POP="${SYNTHEA_POP:-$(cfg population)}";  POP="${POP:-10000}"
SEED="${SYNTHEA_SEED:-$(cfg seed)}";      SEED="${SEED:-42}"
STATE="${SYNTHEA_STATE:-$(cfg state)}";   STATE="${STATE:-Massachusetts}"
JAR_URL="$(cfg jar_url)"
JAR="$(cfg jar_path)";                    JAR="${JAR:-data/tools/synthea-with-dependencies.jar}"
OUT="$(cfg output_dir)";                  OUT="${OUT:-data/synthea}"

command -v java >/dev/null || { echo "java (11+) is required" >&2; exit 1; }
[ -n "$JAR_URL" ] || { echo "synthea.jar_url missing in $CONFIG" >&2; exit 1; }

if [ ! -f "$JAR" ]; then
  echo "Downloading Synthea jar to $JAR"
  mkdir -p "$(dirname "$JAR")"
  curl -fL --retry 3 -o "$JAR.tmp" "$JAR_URL"
  mv "$JAR.tmp" "$JAR"
fi

mkdir -p "$OUT"
CMD=(java -jar "$JAR" -p "$POP" -s "$SEED"
  --exporter.baseDirectory="$OUT"
  --exporter.csv.export=true
  --exporter.fhir.export=false
  --exporter.hospital.fhir.export=false
  --exporter.practitioner.fhir.export=false
  --exporter.ccda.export=false
  --exporter.text.export=false
  "$STATE")

echo "Running: ${CMD[*]}"
"${CMD[@]}"

# The jar has no --version flag; record the jar's identity instead.
SHA="$(shasum -a 256 "$JAR" | awk '{print $1}')"
VERSION="$(unzip -p "$JAR" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' \
  | awk -F': ' '/Implementation-Version|Specification-Version/ {print $2; exit}')"
{
  echo "synthea_version: ${VERSION:-unknown (release: $JAR_URL)}"
  echo "jar_sha256: $SHA"
  echo "java: $(java -version 2>&1 | head -1)"
  echo "run_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "population: $POP"
  echo "seed: $SEED"
  echo "state: $STATE"
  echo "command: ${CMD[*]}"
} > "$OUT/RUN_INFO.txt"

echo "CSV output: $OUT/csv ; run info: $OUT/RUN_INFO.txt"
