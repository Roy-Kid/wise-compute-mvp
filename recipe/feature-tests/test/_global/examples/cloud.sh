#!/bin/sh
# Verify the lightweight delivery from an empty, writable working directory.
set -eu
export LC_ALL=C.UTF-8

test "$(id -u)" -ne 0
for tool in git curl wget jq rg rsync ssh scp patch diff file tar gzip bzip2 xz zip unzip zstd \
    cc c++ make cmake ninja pkg-config python pip fc-match pdffonts pdftotext pdftoppm; do
    command -v "$tool"
done
test -s /etc/ssl/certs/ca-certificates.crt
test "$(command -v python)" = "${WISE_VENV:?}/bin/python"
python --version
python -m pip --version
python -m pip check

for tool in mpirun nvcc lmp pw.x cp2k.ssmp cp2k.psmp soffice; do
    if command -v "$tool" >/dev/null; then
        echo "Unexpected tool in the cloud delivery: $tool" >&2
        exit 1
    fi
done

printf '归档 round trip\n' > sample.txt
for suffix in gz bz2 xz zst; do
    tar -caf "sample.tar.$suffix" sample.txt
    tar -xOf "sample.tar.$suffix" sample.txt > extracted.txt
    cmp sample.txt extracted.txt
done
zip -q sample.zip sample.txt
unzip -p sample.zip sample.txt > extracted.txt
cmp sample.txt extracted.txt

fc-match -f '%{family}\n' ':lang=zh-cn' | grep -E 'Noto (Sans|Serif) CJK|Droid Sans Fallback'
fc-match -f '%{family}\n' 'Noto Sans CJK SC:lang=zh-cn' | grep -F 'Noto Sans CJK SC'
export MPLCONFIGDIR="$PWD/matplotlib-cache"
python - <<'PY'
import os
import warnings

import matplotlib
import matplotlib.pyplot as plt
import numpy as np
from matplotlib import font_manager
from PIL import Image
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas

assert matplotlib.get_backend().lower() == "agg"
assert matplotlib.rcParams["font.family"] == ["Noto Sans CJK SC", "DejaVu Sans"]
assert matplotlib.rcParams["axes.unicode_minus"]
font_manager.findfont("Noto Sans CJK SC", fallback_to_default=False)
warnings.filterwarnings("error", message=r"Glyph .* missing from font")

points = np.array([-1, 0, 1])
fig, ax = plt.subplots(figsize=(5, 3), layout="constrained")
ax.plot(points, points ** 2)
ax.set_xticks(points)
ax.set_title(r"中文图表 / Energy $E = mc^2$")
ax.set_xlabel("位移")
ax.set_ylabel("能量")
fig.savefig("chart.png")
assert ax.get_xticklabels()[0].get_text() == "−1"
with Image.open("chart.png") as chart:
    chart.verify()

pdfmetrics.registerFont(TTFont("Cloud CJK", os.environ["WISE_REPORT_FONT"]))
pdfmetrics.registerFont(TTFont("Cloud Latin", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"))
pdf = Canvas("report.pdf", pagesize=A4)
pdf.setFont("Cloud CJK", 16)
pdf.drawString(40, 780, "中文报告")
pdf.setFont("Cloud Latin", 16)
pdf.drawString(40, 752, "Cloud report −1")
pdf.drawImage("chart.png", 40, 360, width=500, height=300, preserveAspectRatio=True)
pdf.save()
PY
pdftotext -enc UTF-8 report.pdf report.txt
grep -F '中文报告' report.txt
grep -F 'Cloud report −1' report.txt
pdffonts report.pdf | awk '/DroidSansFallback/ && $(NF-4) == "yes" && $(NF-2) == "yes" { found=1 } END { exit !found }'
pdftoppm -f 1 -l 1 -r 72 -png report.pdf report
test -s report-1.png
