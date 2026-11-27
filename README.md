# WiseHub

WiseHub 把材料计算软件做成可组合的 [Dev Container Feature](https://containers.dev/implementors/features/)，再把选定的 Feature 构建成镜像交给计算平台。仓库有两部分：

- [`recipe/`](recipe/README.md)：镜像配方。基座、47 个 Feature、四套交付配置和它们的测试。
- [`cli/`](docs/cli.md)：命令行工具 `wisehub`。构建镜像、检查和发布 Feature、给镜像加平台入口、导出和推拉镜像。

## 交付的镜像

| 交付 | 用途 | 内容 |
| --- | --- | --- |
| [cpu](recipe/delivery/cpu/.devcontainer/devcontainer.json) | 平台的 CPU 计算实例 | Open MPI、LAMMPS、Quantum ESPRESSO、CP2K、Wannier90、Packmol、Multiwfn、材料 Python 包 |
| [cuda](recipe/delivery/cuda/.devcontainer/devcontainer.json) | 平台的 GPU 计算实例，面向 RTX PRO 5000 | 同上，LAMMPS、QE、CP2K 为 GPU 版；NVIDIA HPC SDK 25.7、CUDA 12.9 |
| [smp](recipe/delivery/smp/.devcontainer/devcontainer.json) | 单台云主机，类似超算登录节点 | 无 MPI，求解器为多线程版，默认用满所有核 |
| [cloud](recipe/delivery/cloud/README.md) | 轻量云主机 | 通用工具、Python 和报告生成，无求解器 |

cpu 和 cuda 镜像的最后一层是[平台 SSH 入口](recipe/delivery/compute/README.md)：以 `compute`（1000:1000）启动 2222 端口的 sshd，平台经 SSH 执行任务、经 SFTP/SCP 取回结果。

## 支持的软件

共 47 个 Feature，分类与 [`recipe/`](recipe/README.md) 的目录一致。「交付」列是默认装入该软件的镜像，「按需」表示有 Feature 可选用，现有交付没有装。CPU 基座的 28 个场景和 CUDA 基座的 28 个场景都从头构建并跑过算例；构建机没有 GPU，GPU 上的计算路径尚未实测。

### 应用（applications）

| 类别 | 软件 | 版本 | CUDA 基座上 | 交付 |
| --- | --- | --- | --- | --- |
| 第一性原理 | [Quantum ESPRESSO](recipe/applications/src/quantum-espresso) | 7.6 | GPU 版（OpenACC） | cpu、cuda、smp |
| | [CP2K](recipe/applications/src/cp2k) | 2026.2 | GPU 版 | cpu、cuda、smp |
| | [GPAW](recipe/applications/src/gpaw) | 25.7.0 | GPU 版（`variant: cuda`） | 按需 |
| | [ABACUS](recipe/applications/src/abacus) | 3.10.1 | GPU 版（`variant: cuda`） | 按需 |
| | [JDFTx](recipe/applications/src/jdftx) | 1.7.0 | GPU 版（`variant: cuda`） | 按需 |
| 半经验和紧束缚 | [DFTB+](recipe/applications/src/dftbplus) | 26.1 | 同 CPU 版 | 按需 |
| | [xtb](recipe/applications/src/xtb) | 6.8.0 | 同 CPU 版 | 按需 |
| | [MOPAC](recipe/applications/src/mopac) | 23.2.5 | 同 CPU 版 | 按需 |
| 分子动力学和经典势 | [LAMMPS](recipe/applications/src/lammps) | stable_30Sep2026_update1 | GPU 版（KOKKOS） | cpu、cuda、smp |
| | [GROMACS](recipe/applications/src/gromacs) | 2026.4 | GPU 版（`variant: cuda`） | 按需 |
| | [Asap](recipe/applications/src/asap3) | 3.13.11 | 同 CPU 版 | 按需 |
| | [Atomistica](recipe/applications/src/atomistica) | 1.2.7 | 同 CPU 版 | 按需 |
| | [OpenKIM](recipe/applications/src/kim) | KIM API 2.4.2 | 同 CPU 版 | 按需 |
| 机器学习势 | [DeePMD-kit](recipe/applications/src/deepmd-kit) | 3.2.0 | GPU 版（`variant: cuda`） | 按需 |
| 色散校正 | [DFT-D3](recipe/applications/src/dftd3) | 1.7.0 | 同 CPU 版 | 按需 |
| | [DFT-D4](recipe/applications/src/dftd4) | 4.3.1 | 同 CPU 版 | 按需 |
| 增强采样 | [PLUMED](recipe/applications/src/plumed) | 2.10.2 | 同 CPU 版 | 按需 |
| 建模和分析 | [Wannier90](recipe/applications/src/wannier90) | 3.1.0 | 同 CPU 版 | cpu、cuda、smp |
| | [Packmol](recipe/applications/src/packmol) | 21.2.3 | 同 CPU 版 | cpu、cuda、smp |
| | [Multiwfn](recipe/applications/src/multiwfn) | 2026.11.26 | 同 CPU 版 | cpu、cuda、smp |
| Python | [材料 Python 包](recipe/applications/src/materials-python) | ASE 3.26.0、pymatgen 2025.10.7、spglib 2.6.0、Phonopy 4.10.0、Phono3py 4.10.0、PySCF 2.11.0、pycalphad 0.11.2、MDAnalysis 2.11.0、SciPy 1.17.1、pandas 2.3.3、Matplotlib 3.10.9、h5py 3.16.0 | 同 CPU 版 | cpu、cuda、smp |
| | [NumPy](recipe/applications/src/numpy) | 2.4.6 | 同 CPU 版 | cpu、cuda、smp、cloud |
| | [mpi4py](recipe/applications/src/mpi4py) | 4.1.2 | 同 CPU 版 | cpu、cuda |
| 云主机 | [cloud-host](recipe/applications/src/cloud-host) | 命令行工具、中文字体、绘图和 PDF 报告 | 不适用 | cloud |

[`cp2k-toolchain`](recipe/applications/src/cp2k-toolchain) 和 [`cp2k-integrals`](recipe/applications/src/cp2k-integrals) 是 CP2K 的依赖库，随 CP2K 装入。标「按需」的应用里，除 PLUMED 外的 13 个是为 [ASE 计算器](recipe/README.md#ase-计算器)加的，各自的安装内容和取舍见该节。

### 基础库（infra）

| 类别 | 软件 | 版本 | CUDA 基座上 | 交付 |
| --- | --- | --- | --- | --- |
| SDK | [core](recipe/infra/src/core) | Feature SDK 4 | 相同 | 全部 |
| 编译器 | [GCC、gfortran、OpenMP、CMake](recipe/infra/src/openmp) | Ubuntu 24.04 软件包 | 另有基座的 NVIDIA HPC SDK 25.7 | cpu、cuda、smp |
| MPI | [Open MPI](recipe/infra/src/openmpi) | 5.0.11 | 不装，用基座的 HPC-X Open MPI | cpu |
| | [Open MPI 默认设置](recipe/infra/src/openmpi-defaults) | — | 相同 | cpu、cuda |
| | [MPICH](recipe/infra/src/mpich) | 4.3.2 | 不适用 | 按需 |
| 互连 | [UCX](recipe/infra/src/ucx) | 1.21.1 | 不装，用基座的 HPC-X UCX | cpu |
| | [libfabric](recipe/infra/src/libfabric) | 2.7.0 | 不装 | cpu |
| | [RDMA 用户态库](recipe/infra/src/rdma) | Ubuntu 24.04 软件包 | 不装 | cpu |
| 数学库 | [OpenBLAS（BLAS、LAPACK）](recipe/infra/src/linear-algebra) | Ubuntu 24.04 软件包 | pthread 版 | cpu、cuda、smp |
| | [FFTW](recipe/infra/src/fftw) | 3.3.11 | 相同 | cpu、cuda、smp |
| | [ScaLAPACK](recipe/infra/src/scalapack) | 2.2.3 | 相同 | cpu、cuda |
| | [ELPA](recipe/infra/src/elpa) | 2026.02.002 | GPU 版 | cpu、cuda |
| | [Libxc](recipe/infra/src/libxc) | 6.2.2 | 相同 | 按需 |
| 并行 I/O | [HDF5](recipe/infra/src/hdf5) | 2.2.0 | 相同 | cpu、cuda |
| | [NetCDF-C](recipe/infra/src/netcdf) | 4.10.1 | 相同 | cpu、cuda |

### 工具链（toolchains）

| 软件 | 版本 | 交付 |
| --- | --- | --- |
| [Python 虚拟环境](recipe/toolchains/src/python) | CPython 3.12（Ubuntu 24.04） | cpu、cuda、smp、cloud |
| [Conda](recipe/toolchains/src/conda) | 25.3.1 | cpu、cuda、smp |
| [uv](recipe/toolchains/src/uv) | 0.9.26 | cpu、cuda、smp |
| [Rust](recipe/toolchains/src/rust) | Ubuntu 24.04 软件包 | cpu、cuda、smp |
| [Node.js](recipe/toolchains/src/nodejs) | 24.22.3 | cpu、cuda、smp |

### 供应商（providers）

| 软件 | 说明 | 交付 |
| --- | --- | --- |
| [aliyun](recipe/providers/src/aliyun) | 为阿里云服务器 SDK 预留的 Feature，目前不装任何东西 | 按需 |

还没有 Feature 的 ASE 计算器，以及因许可不在范围内的软件，见[配方说明](recipe/README.md#ase-计算器)。

## 从源码到交付

需要 Node.js 22.18+；构建和测试镜像还需要 Docker、Buildx 和 zstd。各步骤的说明见[发布流程](docs/release.md)。

```bash
npm ci
npm test                                           # 单元测试和 Feature 约定检查，不需要 Docker
npm run test:features -- cpu all                   # 每个 Feature 从基座构建并跑算例
npx wisehub image build --workspace-folder recipe/delivery/cpu --local-features recipe \
    --platform linux/amd64 --image wise-compute:materials-cpu
npm run test:delivery -- cpu wise-compute:materials-cpu
npx wisehub image extend wise-compute:materials-cpu --context recipe/delivery/compute \
    --build-arg COMPUTE_TARGET=aliyun-acs --build-arg VERSION=<版本> \
    --image harbor.will/wise/wise-compute-image:materials-full-cpu-<版本>
sh recipe/delivery/compute/check.sh harbor.will/wise/wise-compute-image:materials-full-cpu-<版本>
npx wisehub image export harbor.will/wise/wise-compute-image:materials-full-cpu-<版本> --output <目录>
```

仓库没有 CI：以上步骤在有 Docker 的构建机上手工执行。

## 文档

| 文档 | 内容 |
| --- | --- |
| [镜像配方](recipe/README.md) | 分层、各交付的内容和取舍、ASE 计算器 Feature、测试的组织 |
| [发布流程](docs/release.md) | 从改动到交付的每一步：测试、构建、验收、入口层、导出、版本号 |
| [Feature SDK](docs/feature-sdk.md) | `core` 提供的函数、Feature 之间的关系怎么声明、`wisehub feature check` 的规则 |
| [CLI 参考](docs/cli.md) | `wisehub` 的全部命令、输出和退出码 |
| [平台 SSH 入口](recipe/delivery/compute/README.md) | 入口层装了什么、SSH 会话的环境、平台式检查 |
| [排障记录](docs/troubleshooting.md) | 构建机、网络、MPI、CUDA 编译和各软件遇到过的问题 |
| [待办](docs/roadmap.md) | 尚未完成和尚未验证的事项 |
