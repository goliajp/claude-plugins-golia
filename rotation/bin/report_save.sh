#!/usr/bin/env bash
#
# rotation kernel — file an executor's close report under the rotation it closed.
#
# The report and the verdict of one rotation share a name: <rid>.md beside
# <rid>.verdict.md in ROTATION_VERDICT_DIR, where <rid> is the id the
# rotation RAN under (the verdict's rid; the `rotationId` its events carry),
# not the id the close trigger has just opened for the next round. Two
# spellings were in use before this script; one writer ends that.
#
# usage: report_save.sh <rid> <report-file>
#   <rid>          the closed rotation's id (the verdict's)
#   <report-file>  the report as the executor delivered it, copied verbatim
#
# An existing <rid>.md is never overwritten: a second save of the same
# rotation is a mistake in the caller's bookkeeping (exit 1), and the file on
# disk stays what it was. Records a `report.saved` event.
#
# exit: 0 saved · 1 <rid>.md already exists · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

[ "$#" -eq 2 ] || { echo "usage: report_save.sh <rid> <report-file>" >&2; exit 2; }
RID=$1
SRC=$2
case "$RID" in ''|*/*|.*) echo "report_save: '$RID' is not a rotation id" >&2; exit 2 ;; esac
[ -f "$SRC" ] || { echo "report_save: no report file at $SRC" >&2; exit 2; }
DIR="${ROTATION_VERDICT_DIR:?project.sh must set ROTATION_VERDICT_DIR}"
OUT="$DIR/$RID.md"
if [ -e "$OUT" ]; then
  echo "report_save: $OUT exists; a rotation has one report, and it is not replaced" >&2
  exit 1
fi
mkdir -p "$DIR"
# written beside the target and renamed, so a reader never sees a half-copied report
cp "$SRC" "$OUT.tmp.$$" && mv "$OUT.tmp.$$" "$OUT"
autorun_record_event report.saved "report=raw:$(python3 -c 'import json,sys; print(json.dumps({"rid": sys.argv[1], "file": sys.argv[2], "bytes": int(sys.argv[3])}))' \
  "$RID" "$OUT" "$(wc -c < "$OUT" | tr -d ' ')")"
echo "report: $OUT"
