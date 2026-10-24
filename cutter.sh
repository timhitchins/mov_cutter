#!/usr/bin/env bash
# cutter - cut a long video into named clips using a CSV, then convert them to MP4.
#
# Layout (always relative to this script, so you can run it from anywhere):
#   source/     put the long .mov here
#   metadata/   put the cuts CSV here
#   cuts/mov/   clips written by "cut"
#   cuts/mp4/   files written by "convert" (or "cut --to mp4")
#
# CSV columns: start,end,name   (times are SS, MM:SS or H:MM:SS)
#
# Run ./cutter.sh --help for usage. See README.md for the full guide.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SOURCE_DIR="$ROOT/source"
META_DIR="$ROOT/metadata"
MOV_DIR="$ROOT/cuts/mov"
MP4_DIR="$ROOT/cuts/mp4"

# ---------- defaults ----------
INPUT_ARG=""
CSV_ARG=""
CUT_TO="mov"      # mov | mp4  (where "cut" writes)
FAST=0            # 1 = stream copy on cut (instant, keyframe-snapped)
MP4_MODE="auto"   # auto | copy | encode  (how "convert" makes MP4s)
CRF=20
FORCE=0
DRY_RUN=0

# Results shared between functions
FAILS=0
P_NAME=(); P_START=(); P_END=(); P_DUR=()
PARSE_BAD=0

usage() {
  cat <<'EOF'
cutter - cut a long video into clips from a CSV, then convert them to MP4

Usage: ./cutter.sh <command> [options]

Commands:
  init       Create the folder layout (safe to run any time)
  check      Validate the CSV against the source video, cut nothing
  cut        Cut clips into cuts/mov (or cuts/mp4 with --to mp4)
  convert    Convert every clip in cuts/mov to MP4 in cuts/mp4
  all        cut (to mov) then convert
  status     Show what is in each folder

Options:
  -i, --input FILE    Source video. A bare filename is looked up in source/.
                      Default: the only .mov in source/
  -c, --csv FILE      Cuts CSV. A bare filename is looked up in metadata/.
                      Default: the only .csv in metadata/
      --to mov|mp4    cut: write clips as .mov (default) or straight to .mp4
      --fast          cut: stream copy, no re-encode. Instant, but cuts snap to
                      keyframes and can be a second or two off
  -m, --mp4-mode M    convert: auto (default) | copy | encode
                        auto   = remux if the clip is H.264/AAC, else re-encode
                        copy   = always remux (lossless, may fail on odd codecs)
                        encode = always re-encode to H.264/AAC
      --crf N         Re-encode quality, lower = better (default 20)
  -f, --force         Overwrite existing output files (default: skip them)
  -n, --dry-run       Print the ffmpeg commands without running them
  -h, --help          Show this help

Common flows:
  ./cutter.sh check                       # validate CSV first
  ./cutter.sh all                         # accurate cuts, then MP4s
  ./cutter.sh cut --fast                  # quick rough cuts
  ./cutter.sh cut --to mp4                # skip the .mov step entirely
  ./cutter.sh convert -m encode --crf 18  # redo MP4s at higher quality
EOF
}

die() { echo "error: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install it with: sudo apt install ffmpeg"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# SS, MM:SS or H:MM:SS, optional decimals on the seconds
valid_time() { [[ "$1" =~ ^[0-9]+(:[0-9]{1,2}){0,2}(\.[0-9]+)?$ ]]; }

to_seconds() {
  awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.3f", s }' <<<"$1"
}

fmt_hms() {
  awk -v t="$1" 'BEGIN { t = int(t + 0.5); printf "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60 }'
}

# Run a command, or just print it in dry-run mode.
run() {
  if (( DRY_RUN )); then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# resolve_file <given> <dir> <ext> <label>
# Explicit path, or bare name inside <dir>, or the single *.<ext> in <dir>.
resolve_file() {
  local given="$1" dir="$2" ext="$3" label="$4"
  if [[ -n "$given" ]]; then
    if [[ -f "$given" ]]; then printf '%s\n' "$given"; return 0; fi
    if [[ -f "$dir/$given" ]]; then printf '%s\n' "$dir/$given"; return 0; fi
    echo "error: $label not found: $given (looked here and in $dir)" >&2
    return 1
  fi
  local -a found=()
  mapfile -t found < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -iname "*.$ext" 2>/dev/null | sort)
  case ${#found[@]} in
    0) echo "error: no .$ext file in $dir - add one or pass it explicitly" >&2; return 1 ;;
    1) printf '%s\n' "${found[0]}"; return 0 ;;
    *) echo "error: several .$ext files in $dir; choose one with --${label}:" >&2
       printf '  %s\n' "${found[@]##*/}" >&2
       return 1 ;;
  esac
}

source_duration() {
  ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -n1
}

# ---------- CSV parsing (shared by check and cut) ----------
# parse_csv <csv> <source_duration or empty>
# Fills P_NAME / P_START / P_END / P_DUR and PARSE_BAD.
parse_csv() {
  local csv="$1" src_dur="$2"
  P_NAME=(); P_START=(); P_END=(); P_DUR=()
  PARSE_BAD=0
  local -A seen=()
  local lineno=0 start end name start_s end_s dur

  while IFS=, read -r start end name _ <&3 || [[ -n "${start:-}" ]]; do
    lineno=$((lineno + 1))
    start=$(trim "${start:-}"); end=$(trim "${end:-}"); name=$(trim "${name:-}")

    [[ -z "$start$end$name" ]] && continue          # blank line
    [[ "$start" == \#* ]] && continue               # comment
    [[ "${start,,}" == "start" ]] && continue       # header row

    if [[ -z "$name" || "$name" == */* || "$name" == .* ]]; then
      echo "  line $lineno: invalid name '$name' - skipped" >&2; PARSE_BAD=$((PARSE_BAD + 1)); continue
    fi
    if [[ -n "${seen[$name]+x}" ]]; then
      echo "  line $lineno ($name): duplicate name - skipped" >&2; PARSE_BAD=$((PARSE_BAD + 1)); continue
    fi
    if ! valid_time "$start" || ! valid_time "$end"; then
      echo "  line $lineno ($name): bad time '$start' or '$end' - skipped" >&2; PARSE_BAD=$((PARSE_BAD + 1)); continue
    fi

    start_s=$(to_seconds "$start"); end_s=$(to_seconds "$end")
    dur=$(awk -v s="$start_s" -v e="$end_s" 'BEGIN { printf "%.3f", e - s }')
    if awk -v d="$dur" 'BEGIN { exit !(d <= 0) }'; then
      echo "  line $lineno ($name): end is not after start - skipped" >&2; PARSE_BAD=$((PARSE_BAD + 1)); continue
    fi
    if [[ -n "$src_dur" ]] && awk -v e="$end_s" -v t="$src_dur" 'BEGIN { exit !(e > t + 1) }'; then
      echo "  line $lineno ($name): end $end is past the end of the source ($(fmt_hms "$src_dur")) - skipped" >&2
      PARSE_BAD=$((PARSE_BAD + 1)); continue
    fi

    seen[$name]=1
    P_NAME+=("$name"); P_START+=("$start_s"); P_END+=("$end_s"); P_DUR+=("$dur")
  done 3< <(tr -d '\r' < "$csv")
}

# Resolve input + csv, validate them. Sets INPUT, CSV, SRC_DUR and parses.
load_job() {
  INPUT=$(resolve_file "$INPUT_ARG" "$SOURCE_DIR" mov input) || exit 1
  CSV=$(resolve_file "$CSV_ARG" "$META_DIR" csv csv) || exit 1
  SRC_DUR=$(source_duration "$INPUT")
  [[ -n "$SRC_DUR" ]] || die "ffprobe could not read: $INPUT"
  echo "Source: ${INPUT#"$ROOT"/}  ($(fmt_hms "$SRC_DUR"))"
  echo "CSV:    ${CSV#"$ROOT"/}"
  echo
  parse_csv "$CSV" "$SRC_DUR"
}

# ---------- commands ----------
cmd_init() {
  mkdir -p "$SOURCE_DIR" "$META_DIR" "$MOV_DIR" "$MP4_DIR" || die "could not create folders"
  echo "Folders ready under $ROOT:"
  echo "  source/     put your .mov here"
  echo "  metadata/   put your cuts .csv here"
  echo "  cuts/mov/   cut clips appear here"
  echo "  cuts/mp4/   MP4 files appear here"
}

cmd_check() {
  load_job
  local i
  printf '%-4s %-30s %-10s %-10s %s\n' "#" "name" "start" "end" "length"
  for i in "${!P_NAME[@]}"; do
    printf '%-4s %-30s %-10s %-10s %s\n' "$((i + 1))" "${P_NAME[$i]}" \
      "$(fmt_hms "${P_START[$i]}")" "$(fmt_hms "${P_END[$i]}")" "$(fmt_hms "${P_DUR[$i]}")"
  done
  echo
  echo "check: ${#P_NAME[@]} valid, $PARSE_BAD problem(s)"
  (( PARSE_BAD == 0 )) || FAILS=$((FAILS + PARSE_BAD))
}

cmd_cut() {
  local dest_dir ext fmt
  if [[ "$CUT_TO" == "mp4" ]]; then dest_dir="$MP4_DIR"; ext="mp4"; fmt="mp4"
  else dest_dir="$MOV_DIR"; ext="mov"; fmt="mov"; fi
  mkdir -p "$dest_dir" || die "cannot create $dest_dir"

  load_job
  (( ${#P_NAME[@]} )) || die "no valid cuts found in the CSV"
  FAILS=$((FAILS + PARSE_BAD))

  local -a enc
  if (( FAST )); then
    enc=(-c copy)
  else
    enc=(-c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p -c:a aac -b:a 192k)
  fi
  local -a extra=()
  [[ "$ext" == "mp4" ]] && extra=(-movflags +faststart)

  echo "Writing to: ${dest_dir#"$ROOT"/}/  (.${ext}, $( ((FAST)) && echo 'fast stream copy' || echo 'accurate re-encode'))"
  echo

  local i total=${#P_NAME[@]} done_n=0 skip_n=0 fail_n=0 out tmp
  for i in "${!P_NAME[@]}"; do
    out="$dest_dir/${P_NAME[$i]}.$ext"
    if [[ -e "$out" && $FORCE -eq 0 ]]; then
      echo "[$((i + 1))/$total] skip (exists): ${out#"$ROOT"/}"; skip_n=$((skip_n + 1)); continue
    fi
    echo "[$((i + 1))/$total] ${P_NAME[$i]}  ($(fmt_hms "${P_START[$i]}") -> $(fmt_hms "${P_END[$i]}"))"
    tmp="$out.part"
    if run ffmpeg -nostdin -hide_banner -loglevel error -stats -y \
         -ss "${P_START[$i]}" -i "$INPUT" -t "${P_DUR[$i]}" "${enc[@]}" "${extra[@]}" -f "$fmt" "$tmp"; then
      (( DRY_RUN )) || mv -f "$tmp" "$out"
      done_n=$((done_n + 1))
    else
      rm -f "$tmp"; echo "  failed: ${P_NAME[$i]}" >&2; fail_n=$((fail_n + 1))
    fi
  done

  echo
  echo "cut summary: $done_n done, $skip_n skipped, $fail_n failed, $PARSE_BAD CSV row(s) rejected"
  FAILS=$((FAILS + fail_n))
}

codec_of() { # <file> <v|a>
  ffprobe -v error -select_streams "$2:0" -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -n1
}

cmd_convert() {
  [[ -d "$MOV_DIR" ]] || die "no such folder: cuts/mov (run 'cut' first)"
  local -a files=()
  mapfile -t files < <(find "$MOV_DIR" -maxdepth 1 -type f -iname '*.mov' | sort)
  (( ${#files[@]} )) || die "no .mov files in cuts/mov (run 'cut' first)"
  mkdir -p "$MP4_DIR" || die "cannot create cuts/mp4"

  echo "Converting cuts/mov -> cuts/mp4  (mode: $MP4_MODE)"
  echo

  local f base out tmp vc ac mode n=0 total=${#files[@]} done_n=0 skip_n=0 fail_n=0
  local -a args
  for f in "${files[@]}"; do
    n=$((n + 1))
    base=$(basename "${f%.*}")
    out="$MP4_DIR/$base.mp4"
    if [[ -e "$out" && $FORCE -eq 0 ]]; then
      echo "[$n/$total] skip (exists): ${out#"$ROOT"/}"; skip_n=$((skip_n + 1)); continue
    fi

    mode="$MP4_MODE"
    if [[ "$mode" == "auto" ]]; then
      vc=$(codec_of "$f" v); ac=$(codec_of "$f" a)
      if [[ "$vc" == "h264" && ( -z "$ac" || "$ac" == "aac" ) ]]; then mode="copy"; else mode="encode"; fi
    fi
    if [[ "$mode" == "copy" ]]; then
      args=(-c copy)
    else
      args=(-c:v libx264 -crf "$CRF" -preset medium -pix_fmt yuv420p -c:a aac -b:a 192k)
    fi

    echo "[$n/$total] $base  ($mode)"
    tmp="$out.part"
    if run ffmpeg -nostdin -hide_banner -loglevel error -stats -y -i "$f" \
         "${args[@]}" -movflags +faststart -f mp4 "$tmp"; then
      (( DRY_RUN )) || mv -f "$tmp" "$out"
      done_n=$((done_n + 1))
    else
      rm -f "$tmp"; echo "  failed: $base" >&2; fail_n=$((fail_n + 1))
    fi
  done

  echo
  echo "convert summary: $done_n done, $skip_n skipped, $fail_n failed"
  FAILS=$((FAILS + fail_n))
}

cmd_status() {
  local d label n size
  for d in "source:$SOURCE_DIR" "metadata:$META_DIR" "cuts/mov:$MOV_DIR" "cuts/mp4:$MP4_DIR"; do
    label="${d%%:*}"; d="${d#*:}"
    if [[ -d "$d" ]]; then
      n=$(find "$d" -maxdepth 1 \( -type f -o -type l \) ! -name '.gitkeep' ! -name '*.part' | wc -l)
      size=$(du -shL "$d" 2>/dev/null | cut -f1)
      printf '%-10s %3s file(s)  %s\n' "$label" "$n" "$size"
    else
      printf '%-10s missing (run ./cutter.sh init)\n' "$label"
    fi
  done
}

# ---------- main ----------
[[ $# -ge 1 ]] || { usage; exit 1; }
COMMAND="$1"; shift
case "$COMMAND" in
  init|check|cut|convert|all|status) ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "unknown command: $COMMAND" >&2; echo >&2; usage >&2; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)    [[ $# -ge 2 ]] || die "$1 needs a value"; INPUT_ARG="$2"; shift 2 ;;
    -c|--csv)      [[ $# -ge 2 ]] || die "$1 needs a value"; CSV_ARG="$2"; shift 2 ;;
    --to)          [[ $# -ge 2 ]] || die "$1 needs a value"; CUT_TO="$2"; shift 2 ;;
    -m|--mp4-mode) [[ $# -ge 2 ]] || die "$1 needs a value"; MP4_MODE="$2"; shift 2 ;;
    --crf)         [[ $# -ge 2 ]] || die "$1 needs a value"; CRF="$2"; shift 2 ;;
    --fast)        FAST=1; shift ;;
    -f|--force)    FORCE=1; shift ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (see --help)" ;;
  esac
done

case "$CUT_TO" in mov|mp4) ;; *) die "--to must be mov or mp4" ;; esac
case "$MP4_MODE" in auto|copy|encode) ;; *) die "--mp4-mode must be auto, copy, or encode" ;; esac
[[ "$CRF" =~ ^[0-9]+$ ]] || die "--crf must be a number"
[[ "$COMMAND" == "all" && "$CUT_TO" == "mp4" ]] && die "'all' always cuts to .mov first; use 'cut --to mp4' to skip the .mov step"

if [[ "$COMMAND" != "init" && "$COMMAND" != "status" ]]; then
  need ffmpeg; need ffprobe; need awk
fi

case "$COMMAND" in
  init)    cmd_init ;;
  status)  cmd_status ;;
  check)   cmd_check ;;
  cut)     cmd_cut ;;
  convert) cmd_convert ;;
  all)     cmd_cut; echo; cmd_convert ;;
esac

(( FAILS == 0 )) || exit 1
exit 0
