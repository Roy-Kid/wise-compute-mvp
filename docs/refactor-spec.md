# WiseHub 全量重构规范

状态为实施中。本规范定义新的仓库结构、构建输入和发布契约。迁移采用一次性替换。新项目的唯一 CLI 是 `wisehub`，公开命令统一放在 `wisehub image` 下。

每个产品版本交付两个独立的 all-in-one OCI 镜像，CPU 和 CUDA 各一个。两版提供同一套用户可调用的科学计算应用和工具，并分别返回可直接部署的镜像 digest。Platform 仅提供第一批能力和验收场景的参考。

## 1. 仓库结构

五个层级统一放在 `stack/` 下，目录名对应各层职责。三级 Feature 集合各有官方 Feature Starter 所用的 `src/<id>` 和 `test/<id>`。

```text
stack/
├── base/
│   ├── cpu/.devcontainer/devcontainer.json
│   └── cuda/.devcontainer/devcontainer.json
├── compute/
│   ├── src/{openmp,openmpi,mpich,linear-algebra,scalapack}/
│   └── test/<id>/
├── toolchains/
│   ├── src/{python,conda,uv,rust,nodejs}/
│   └── test/<id>/
├── applications/
│   ├── src/{numpy,mpi4py,lammps,cp2k,quantum-espresso,wannier90,packmol}/
│   └── test/<id>/
└── delivery/
    ├── cpu/.devcontainer/devcontainer.json
    └── cuda/.devcontainer/devcontainer.json
src/cli/
docs/
```

`stack/base` 的配置用于验证上游底座。`stack/compute`、`stack/toolchains` 和 `stack/applications` 分开维护原生 Feature 源码与测试。`stack/delivery` 定义最终组合，允许在各工作区放配方专用的 Dockerfile 和验证脚本。

## 2. 底座与层级

| 层级 | 开发和交付约定 |
| --- | --- |
| **系统基座** | CPU 使用 Ubuntu 24.04 官方 OCI 镜像。CUDA 使用 NVIDIA 官方 CUDA runtime 的 Ubuntu 24.04 变体。两版初期均为 `linux/amd64`，各自锁定上游 manifest digest。需要 GPU 编译时，构建阶段使用相同 CUDA 版本及 Ubuntu 版本的 NVIDIA `devel` 镜像。 |
| **计算运行库** | OpenMP、Open MPI、MPICH、线性代数库和 ScaLAPACK 各自是独立 Feature。交付默认 Open MPI。MPICH 是可选配方，切换时须重新验证所有 MPI 绑定。每个交付配方只选择一种 MPI 实现。 |
| **语言与工具链** | Python、Conda、uv、Rust、Node.js 分别提供标准 Feature 和验收。允许引用合格的上游 Feature，按版本锁定。首版两份交付配方都显式纳入这五项。构建应用所需的额外编译器、头文件和源码可留在构建阶段。 |
| **科学应用** | NumPy、mpi4py、LAMMPS、CP2K、Quantum ESPRESSO、Wannier90、Packmol 独立安装、独立版本化。应用所需的插件、势函数、赝势和基组使用应用专属输入或独立数据 Feature。Platform 参考清单中的其余 Python 分析能力列入同层验收清单，正式交付前逐项确定 Feature 与验证方式。 |
| **最终交付** | CPU 与 CUDA 分别维护一份标准 Dev Container 配方，选择固定基座和各层 Feature。每版镜像包含完整应用组合及运行所需资源。CI、部署和版本回滚消费该版最终 digest。 |

系统底座和计算库共同定义计算基座。预构建的共同层可以作为内部缓存和构建输入。外部交付单位是 CPU 和 CUDA 各自的最终镜像。

NVIDIA 用户空间库来自 CUDA 上游镜像，仓库只有 CPU 和 CUDA 的基座声明，无 NVIDIA 安装 Feature。CUDA 发行资格要求实际在目标 GPU 上运行至少一个已经声明为 CUDA 加速的材料应用。首批目标是验证 LAMMPS 和 CP2K 的 CUDA 路径。CUDA 应用的架构、驱动和编译选项由各自配方锁定。

## 3. 原生 Feature 契约

- 每个本地 Feature 在 `src/<id>/` 提供 `devcontainer-feature.json` 和可执行 `install.sh`，ID 和目录名一致，版本用 SemVer。安装时的选项全部由原生 Feature 元数据声明。
- 每个 Feature 用 `test/<id>/test.sh` 或原生 scenario 测试验证。需要联合验证的 MPI、Python 或 CUDA 应用组合以标准 Dev Container 工作区作为测试输入。
- 强依赖用 `dependsOn`。只要求安装次序用 `installsAfter`。生产跨集合依赖使用完整 OCI Feature 引用。官方 CLI 负责解析依赖、检测环并生成和验证其原生锁文件。
- Feature 安装脚本负责安装自身所需的固定版本输入。包管理器继续负责自身生态的依赖解析。生产构建的系统包来源、语言环境锁、编译产物和直链下载都需标明版本或校验值。
- 发布 CI 先测试并发布引用的 Feature，再构建最终配方。发布配方通过原生锁引用已经存在的 OCI Feature。同一配方可以脱离 WiseHub 交给官方 Dev Container CLI 使用。

Feature 目录与测试布局遵循 [Dev Container Feature Starter](https://github.com/devcontainers/feature-starter)。Feature 元数据和引用遵循 [Dev Container Feature 规范](https://github.com/devcontainers/spec/blob/main/docs/specs/devcontainer-features.md)。

## 4. CLI 和 Registry

| 入口 | 职责 |
| --- | --- |
| `wisehub image build` | 从标准 Dev Container 工作区或指定配置调用官方 CLI 构建，保留其公开参数。 |
| `wisehub image <native-command>` | 在 `image` 下提供上游 `features`、`templates`、`up`、`exec` 等能力。 |
| `wisehub image push` | 通过 OCI 后端发布镜像，读回确认的远端 digest。 |
| `wisehub image pull` | 解析 tag 后按 digest 下载，或者直接拉取给定 digest。 |

构建引擎固定 Dev Container CLI 版本，Registry 后端通过接口注入。首个 Registry 环境是 `harbor.will`。发布记录区分本地镜像 ID 与远端 manifest digest，并记录 CPU 或 CUDA 变体。市场接口保持推送与拉取两个操作。

## 5. CI 和版本

1. 对三个 Feature 集合分别执行官方 `features test` 和 `features package`。在测试 Registry 验证跨层依赖和原生锁。
2. 对 CPU 与 CUDA 工作区以冻结输入独立构建。发布记录绑定源码 commit、基座 digest、Feature 锁、包和下载锁，以及构建工具版本。
3. CPU 在无 GPU 节点上验收应用、MPI 和 OpenMP。CUDA 在有 GPU 的目标节点上运行共同算例及显式启用 GPU 的算例，并核对结果和设备路径。
4. 通过的候选发布到项目的 CPU 与 CUDA 版本引用。两个变体各有最终 digest。同一版本身份不可覆盖，依赖更新经新版本交付。

第一批应用能力以 Platform 的公开软件清单为对照。计划中的必测范围包括 MPI 双进程通信、LAMMPS、QE 与 Wannier90 配套算例、Packmol 和 Python 数值分析。CP2K、CUDA 加速和工具链属于此次新配方的独立验收项。Platform 运行环境的兼容验收通过接口和真实作业验证，Platform 的脚本、Conda 锁和仓库布局留在原项目。

## 6. 一次性切换

实施时移除旧顶层 `features/`、`images/` 和旧示例入口，取消聚合 Feature、`materials` 路径和旧 CLI 名称。读取和构建入口采用标准 Dev Container 文件与官方命令。README、CI 和测试一次更新到新结构。最终镜像产出以真实 Docker 构建、GPU/CPU 验收、Harbor 推送和干净工作器按 digest 拉取为准。
