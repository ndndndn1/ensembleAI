#!/usr/bin/env bash
# Extract structured fields from agent answers and compute majority vote.

# extract_block <file>: prints lines between "=== STRUCTURED ===" and "=== END ==="
extract_block() {
  awk '
    /^=== *STRUCTURED *===/ {capture=1; next}
    /^=== *END *===/        {capture=0}
    capture {print}
  ' "$1"
}

# extract_field <file> <field>: prints the value of FIELD: from the structured block
extract_field() {
  extract_block "$1" \
    | awk -v f="$2" 'BEGIN{IGNORECASE=1} $0 ~ "^"f": " { sub("^"f": ", ""); print; exit }'
}

# extract_conclusion <file>: best-effort CONCLUSION line; falls back to last non-empty line
extract_conclusion() {
  local c
  c="$(extract_field "$1" CONCLUSION)"
  if [[ -z "$c" ]]; then
    c="$(awk 'NF{last=$0} END{print last}' "$1")"
  fi
  printf '%s\n' "$c"
}

# normalize_for_vote: lowercase, collapse whitespace, drop punctuation
normalize_for_vote() {
  tr '[:upper:]' '[:lower:]' \
    | tr -d '"`' \
    | sed -e 's/[[:punct:]]/ /g' -e 's/[[:space:]]\+/ /g' -e 's/^ //;s/ $//'
}

# majority_vote <round_dir>: writes a vote summary to stdout
#   - lists each agent's normalized conclusion
#   - groups them by exact-match equivalence after normalization
#   - identifies the plurality winner
majority_vote() {
  local dir="$1"
  local tmp
  tmp="$(mktemp)"
  for f in "$dir"/*.md; do
    [[ -f "$f" ]] || continue
    local agent
    agent="$(basename "$f" .md)"
    local raw norm
    raw="$(extract_conclusion "$f")"
    norm="$(printf '%s' "$raw" | normalize_for_vote)"
    printf '%s\t%s\t%s\n' "$agent" "$norm" "$raw" >> "$tmp"
  done

  echo "Per-agent CONCLUSION lines:"
  awk -F'\t' '{printf "  - %s: %s\n", $1, $3}' "$tmp"
  echo
  echo "Vote groups (by normalized conclusion):"
  awk -F'\t' '{print $2}' "$tmp" | sort | uniq -c | sort -rn \
    | awk '{count=$1; $1=""; sub(/^ /,""); printf "  %d × \"%s\"\n", count, $0}'
  echo
  local winner_count winner_norm total
  total="$(wc -l < "$tmp" | tr -d ' ')"
  read -r winner_count winner_norm < <(
    awk -F'\t' '{print $2}' "$tmp" | sort | uniq -c | sort -rn | head -n1 \
      | awk '{c=$1; $1=""; sub(/^ /,""); print c"\t"$0}' | tr '\t' ' '
  )
  if [[ -n "$winner_norm" && "$winner_count" -gt 1 ]]; then
    echo "Plurality: $winner_count/$total agents agree on: \"$winner_norm\""
  else
    echo "No majority — all $total agents disagree."
  fi
  rm -f "$tmp"
}
