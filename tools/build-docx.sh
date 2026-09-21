#!/usr/bin/env bash
# Build a shareable .docx of the proposal.
#
# Pandoc's default docx leans on named styles (Table, SourceCode, BlockQuote) that carry almost no
# visual formatting, and relies on Word resolving them. Google Docs does not resolve them the same
# way, so tables import borderless and code blocks import as bare monospace with no box -- they look
# "missing" even though the content is there. This script therefore injects the formatting INLINE,
# so rendering never depends on a style lookup in whichever editor the reader opens it in.
#
# Also drops pandoc's --toc: it emits a Word FIELD that Word fills on F9 and Google Docs shows blank.
# Google Docs builds its own outline from the heading styles (View > Show outline), which is better.
#
# Not part of the evidence harness -- it reads the proposal and writes a document, and touches
# nothing the runs in evidence/ depend on.
#
# usage: tools/build-docx.sh [OUTPUT.docx]
#   default output: ~/Desktop/LimeChain-FRED-v3-proposal-DRAFT.docx
#   a sibling .md (same name, banner stripped) is written alongside it
#   set PANDOC=/path/to/pandoc to use a pandoc that is not on PATH
#   set PROPOSAL=<path.md> to build a different edition (default: the second edition)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="${1:-$HOME/Desktop/LimeChain-FRED-v3-proposal-DRAFT.docx}"
SRC="${PROPOSAL:-proposals/2026-09-LimeChain-FRED-v3.md}"

PANDOC="${PANDOC:-$(command -v pandoc || echo /tmp/pandoc-dist/pandoc-3.11-arm64/bin/pandoc)}"
[ -x "$PANDOC" ] || { echo "pandoc not found. Install it, or fetch the release binary:" >&2
  echo "  https://github.com/jgm/pandoc/releases (arm64-macOS.zip)" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The repo-copy banner makes sense inside the repository, not in a document being emailed.
python3 - "$SRC" "$TMP/src.md" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'^> \*\*This is the copy held.*?\n\n', '', s, flags=re.S | re.M)
open(sys.argv[2], 'w').write(s)
PY

"$PANDOC" "$TMP/src.md" -f gfm -t docx -V lang=en-GB -o "$TMP/raw.docx" || exit 1

python3 - "$TMP/raw.docx" "$OUT" <<'PY'
import sys, zipfile, xml.dom.minidom

src, dst = sys.argv[1], sys.argv[2]

def borders(tag, edges, sz=6, color="999999"):
    return f'<w:{tag}>' + ''.join(
        f'<w:{e} w:val="single" w:sz="{sz}" w:space="0" w:color="{color}"/>' for e in edges
    ) + f'</w:{tag}>'

TBL_B  = borders("tblBorders", ("top","left","bottom","right","insideH","insideV"))
CELL_B = borders("tcBorders",  ("top","left","bottom","right"))
# Code: light grey fill plus a left rule, the way the markdown renders it.
CODE   = ('<w:shd w:val="clear" w:color="auto" w:fill="F4F4F6"/>'
          '<w:pBdr><w:left w:val="single" w:sz="18" w:space="6" w:color="B4BAC2"/>'
          '<w:top w:val="single" w:sz="2" w:space="4" w:color="DDE0E4"/>'
          '<w:bottom w:val="single" w:sz="2" w:space="4" w:color="DDE0E4"/>'
          '<w:right w:val="single" w:sz="2" w:space="4" w:color="DDE0E4"/></w:pBdr>'
          '<w:spacing w:before="120" w:after="120"/><w:ind w:left="120" w:right="120"/>')
# Blockquotes carry the supersession and scope notices; give them a rule, not a fill.
QUOTE  = ('<w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="8A8F97"/></w:pBdr>'
          '<w:spacing w:before="120" w:after="120"/><w:ind w:left="200"/>')

zin, zout = zipfile.ZipFile(src), zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED)
for it in zin.infolist():
    data = zin.read(it.filename)
    if it.filename == "word/document.xml":
        x = data.decode("utf8")
        x = x.replace('<w:tblW w:type="auto" w:w="0" />', '<w:tblW w:type="pct" w:w="5000"/>' + TBL_B)
        x = x.replace('<w:tcPr />', f'<w:tcPr>{CELL_B}</w:tcPr>')
        x = x.replace('<w:pStyle w:val="SourceCode" />', '<w:pStyle w:val="SourceCode" />' + CODE)
        x = x.replace('<w:pStyle w:val="BlockQuote" />', '<w:pStyle w:val="BlockQuote" />' + QUOTE)
        xml.dom.minidom.parseString(x)          # refuse to write a malformed document
        data = x.encode("utf8")
    zout.writestr(it, data)
zout.close()

x = zipfile.ZipFile(dst).read("word/document.xml").decode("utf8")
sc = x.count('w:val="SourceCode"')
bq = x.count('w:val="BlockQuote"')
toc = "yes" if "instrText" in x else "no"
print("  tables %d (bordered %d) | code blocks %d (shaded %d) | quotes %d | TOC field: %s"
      % (x.count("<w:tbl>"), x.count("<w:tblBorders>"), sc, x.count("F4F4F6"), bq, toc))
PY
# Also emit the stripped Markdown next to the docx. The banner-free source already exists as
# $TMP/src.md; copying it here means the two colleague-facing copies cannot drift, and neither
# depends on remembering an ad-hoc command.
MD_OUT="${OUT%.docx}.md"
cp "$TMP/src.md" "$MD_OUT"
echo "  -> $OUT"
echo "  -> $MD_OUT"
