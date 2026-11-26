# 轻量 CPU 云主机镜像

[MR !1](http://git.will.wq/lijichen/wise-compute-mvp/-/merge_requests/1/diffs) 中的轻量云主机配方基于 Ubuntu 24.04 CPU 基座和同一 APT 快照，使用现有的 Python 和 NumPy Feature。

- 通用工具有 Git、curl、wget、jq、ripgrep、rsync、SSH/SCP、patch、diff 和 file，并支持 tar、gzip、bzip2、xz、zip 和 Zstandard。基础编译工具包括 GCC/G++、Make、CMake、Ninja、pkg-config 和 Python 头文件。
- Python、pip 和报告依赖位于 `/opt/venv`。NumPy、Matplotlib、Pillow 和 ReportLab 使用带 SHA-256 的 wheel 锁定版本。
- Matplotlib 默认使用无图形界面的 Agg 后端，字体按 Noto Sans CJK SC、DejaVu Sans 的顺序查找。系统包含 Noto CJK、DejaVu、Liberation 和 Fontconfig。
- ReportLab 是默认 PDF 后端。在脚本中调用 `pdfmetrics.registerFont(TTFont("Cloud CJK", os.environ["WISE_REPORT_FONT"]))` 注册可嵌入的 CJK TrueType 字体，再用 `setFont("Cloud CJK", 12)` 绘制中文正文。英文和负号可使用 DejaVu Sans。Poppler 提供字体、文本和页面检查工具。

需要在单台云主机上运行材料求解器时使用 [SMP 镜像](../smp/.devcontainer/devcontainer.json)。Office 原生预览由 WiSE 自带的 LibreOffice kit 处理。Jupyter、Pandoc/XeLaTeX、Chromium/Playwright 和系统 LibreOffice 可按工作负载另选。

## 构建与验收

在仓库根目录执行。

~~~bash
npm ci
npx wisehub image build --workspace-folder recipe/delivery/cloud --local-features recipe \
  --platform linux/amd64 --image wise-compute:cloud-host
npm run test:delivery -- cloud wise-compute:cloud-host
~~~

验收以非 root 用户离线运行，检查 CLI、压缩包往返、Python 解释器及依赖，并生成含中英文、负号、公式与图表的 PDF。它检查缺失字形、PDF 字体嵌入、中文文本提取和页面渲染。也可运行 `npm run test:features -- cloud` 验收 Feature。

在云主机上，可用 `ssh USER@TEST_HOST true` 与 `scp FILE USER@TEST_HOST:REMOTE_PATH` 检查到实际测试目标的连通性与文件传输。
