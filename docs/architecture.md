# WiseHub 架构

本文只描述**已经实现并由测试或 CI 守护**的契约。计划中的能力见 [roadmap](roadmap.md)。

仓库是一个 npm workspaces 单仓，包含两个独立演进的部分：

| 目录 | 内容 | 验证 |
| --- | --- | --- |
| [`cli/`](../cli) | `wisehub` 命令行：构建 Dev Container 工作区为本地镜像，按 digest 推送和拉取 | `npm test -w cli`，[cli.yml](../.github/workflows/cli.yml) |
| [`stack/`](../stack) | 科学计算镜像配方：Feature 集合、CPU/CUDA 配方、验收脚本 | `npm test -w stack`、`npm run test:features -w stack`，[stack.yml](../.github/workflows/stack.yml) |

两者之间唯一的接口是标准 Dev Container 工作区：`stack` 渲染出工作区，`wisehub image build` 或官方 `devcontainer` CLI 构建它。

## stack

```text
stack/
├── stack.json              # 唯一配置源：apt 快照、分层安装顺序、各变体的基座镜像
├── features/
│   ├── src/<id>/           # devcontainer-feature.json + install.sh
│   └── test/<id>/          # test.sh，或 scenarios.json + <scenario>.sh
├── recipes/
│   ├── cpu/Dockerfile
│   ├── cuda/Dockerfile     # 额外编译 lmp-cuda
│   └── verify.sh           # 交付镜像验收
└── src/                    # render / test-features 脚本
```

### stack.json

- `tiers` 按 compute → toolchains → applications 列出 Feature，拼接后即安装顺序。CPU 与 CUDA 共用同一列表，不存在两份需要同步的清单。
- `variants.<name>.buildArgs` 传给 `recipes/<name>/Dockerfile`；所有 `*_IMAGE` 必须按 digest 锁定。
- `aptSnapshot` 写入 `/etc/apt/apt.conf.d/50wise-snapshot`，此后所有 `apt-get`（包括 Feature 内的）都解析到同一个 [Ubuntu 快照](https://snapshot.ubuntu.com)。升级系统包 = 修改这一个时间戳。

`loadStack()` 在渲染前校验以上约束（未知 Feature、重复、未锁定镜像、缺失 Dockerfile、快照格式）。

### 渲染

`npm run render -w stack -- [variant...] [--feature-registry REF]` 为每个变体生成 `stack/build/recipes/<variant>/.devcontainer/`：

- 本地模式：Feature 源码复制到 `.devcontainer/features/<id>`，以 `./features/<id>` 引用。
- 发布模式：以 `REF/<id>:<version>` 引用已发布的 OCI Feature。

两种模式都写出 `overrideFeatureInstallOrder`。**安装顺序只由配方决定。** 没有它时官方 CLI 按字母序安装（mpi4py 会排在 python 和 openmpi 之前），测试会在顺序偏离 `stack.json` 时失败。

渲染产物不入库；`.devcontainer` 里不再有软链接。

### Feature 契约

由 [stack.test.ts](../stack/test/stack.test.ts) 逐条检查：

- `id` 与目录名一致，`version` 为 SemVer。
- 不使用 `dependsOn` / `installsAfter`。相对路径引用在发布到 OCI 后会失效，顺序由配方负责。
- `install.sh` 可执行，以 `#!/bin/sh` 和 `set -eu` 开头。
- 依赖其他 Feature 的，在安装时显式检查前置条件并给出错误，例如 `: "${WISE_VENV:?install the python Feature before numpy}"`。
- python Feature 通过 `containerEnv` 导出 `WISE_VENV`（以及 `PATH`），后续 Feature 和验收脚本只通过这个变量定位虚拟环境。
- 能独立安装的 Feature 用 `test/<id>/test.sh`，在 `stack.json` 的 CPU 基座上运行；有前置条件的用 `scenarios.json` 声明，场景镜像必须与 CPU 基座一致。

### CUDA

NVIDIA 用户态库来自 CUDA runtime 基座。`recipes/cuda/Dockerfile` 在同版本 devel 镜像中编译 GPU 版 LAMMPS，作为 `lmp-cuda` 复制进最终镜像。最终镜像移除 NVIDIA apt 源，使所有包来源都受快照约束。

## cli

```text
cli/src/
├── cli.ts        # 参数解析与输出（stdout 为 JSON，进度走 stderr）
├── build.ts      # DevContainerBuilder：调用锁定版本的 devcontainer build
├── registry.ts   # OciRegistry：push / pull 的确认逻辑
├── docker.ts     # 所有 docker 调用及 registry 错误分类
├── reference.ts  # 镜像引用与平台解析
└── process.ts    # 子进程执行
```

依赖方向：`cli → build/registry → docker → process`，`reference` 为纯函数。测试通过向 `Docker` 注入假的进程执行器覆盖全部分支，不需要 Docker。

命令与传输语义见 [protocol-v1](protocol-v1.md)。
