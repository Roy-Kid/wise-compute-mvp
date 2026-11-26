# 材料计算镜像配方

| 层 | 内容 |
| --- | --- |
| [base](base) | CPU 用 Ubuntu 24.04，CUDA 用 NVIDIA HPC SDK 25.7（CUDA 12.9）及 GDRCopy。基座锁定 digest，apt 使用 Ubuntu 快照。 |
| [infra](infra/src) | Feature SDK、编译器、MPI、互连、数学库和并行 I/O。 |
| [toolchains](toolchains/src) | Python、Conda、uv、Rust 和 Node.js。 |
| [applications](applications/src) | LAMMPS、Quantum ESPRESSO、CP2K、Wannier90、Packmol、材料 Python 工具、mpi4py 和可选的 PLUMED。 |
| [providers](providers/src) | 按服务器供应商选用的 SDK Feature。[`aliyun`](providers/src/aliyun) 目前只登记 Feature。 |
| [delivery](delivery) | CPU/CUDA Dev Container 配置、验收和基准脚本。 |

供应商 Feature 由交付配置的 `features` 显式选用。阿里云占位项的发布引用为 `harbor.will/wise/wise-compute-features/providers/aliyun:1`。

## 编写 Feature

每个 Feature 由 `devcontainer-feature.json` 和 `install.sh` 组成。元数据记录选项和依赖，安装脚本固定上游源版本并调用 [Feature SDK](infra/src/core/feature.sh)。

```sh
#!/bin/sh
set -eu
wise_id=example
. /usr/local/lib/devcontainer-features/feature.sh
wise_require_capability mpi
wise_require fftw
wise_require_if "${ELPA:-false}" elpa
# 安装到 $WISE_PREFIX，并用 wise_linked 检查链接。
wise_done
```

- 无条件依赖写入 `dependsOn`，条件依赖和能力提供者写入 `installsAfter`。依赖指向同层或下层，以 `harbor.will/wise/wise-compute-features/<层>/<id>:<主版本>` 引用。
- CPU 交付通过 Feature 安装 Open MPI，使用 UCX 和 libfabric。可选 MPICH 使用 libfabric。
- 基座通过 `WISE_BASE_<能力>` 声明已有能力。CUDA 设置 `WISE_BASE_MPI=openmpi` 和 `WISE_MPI_ROOT`，让 Feature 复用 SDK 自带的 HPC-X 和 UCX。重复选中 MPI 提供者会报错。使用 MPI 的 CUDA 版 Fortran 库按同一个 `nvfortran` ABI 构建。
- CUDA 版 CP2K 是例外。它需要 gfortran（nvfortran 编不过 DBCSR），而 HPC-X 只提供 nvfortran 的 MPI Fortran 模块，所以 CP2K 的工具链在 `/usr/local/cp2k-deps` 自建一套 GNU 依赖和 Open MPI。这套依赖不进默认 `PATH` 和动态库缓存，`cp2k.psmp` 等命令自行设置环境，并行运行用 `cp2k-mpirun`；用镜像的 `mpirun` 启动会被拒绝。
- 没有 MPI 的镜像里，FFTW、LAMMPS、Quantum ESPRESSO 和 CP2K 自动构建为多线程程序（`lmp`、`pw.x`、`cp2k.ssmp`），OpenMP 和 OpenBLAS（包括 NumPy、SciPy 自带的那份）默认用满所有核。有 MPI 时由 MPI 提供者设置 `OMP_NUM_THREADS=1` 和 `OPENBLAS_NUM_THREADS=1`，即每个进程一个线程。ScaLAPACK、ELPA、并行 HDF5 和 NetCDF、mpi4py 以及 CP2K 的 `largeSystems` 都需要 MPI。
- CUDA、NVIDIA HPC SDK 和 GDRCopy 由 CUDA 基座提供。CPU 指令集基线是 x86-64-v3，每个进程只加载一套 OpenMP 运行时。
- 修改 Feature 后递增其 `version`，升主版本时更新引用。发布和本地构建见 [CLI 用法](../docs/cli.md)。

## 交付配置

材料 CPU 完整镜像的应用名为 `materials-full`。在 `harbor.will/wise/wise-compute-image` 使用 `<app>-<variant>-<version>` 标签。开发候选版使用 SemVer 的 `-dev.N` 后缀，正式版使用 `MAJOR.MINOR.PATCH`。构建输入、镜像版本和各应用版本见 [Lavas 发布配方](delivery/cpu/lavas-release.json)。

| 应用 | CPU | CUDA |
| --- | --- | --- |
| LAMMPS | MPI、OPENMP、FFTW3、H5MD、NETCDF | 加 KOKKOS（`BLACKWELL120`）和 cuFFT |
| Quantum ESPRESSO | GCC、MPI、OpenMP、ScaLAPACK、ELPA、HDF5 | nvfortran、OpenACC、GPU-aware MPI，编译 `sm_120` |
| CP2K | ELPA、HDF5、`largeSystems` | 使用 GCC 和 CUDA 构建，启用 ELPA、HDF5 和 `largeSystems`，编译 `sm_120`；运行在自带的 GNU 栈和 Open MPI 上，用 `cp2k-mpirun` 启动 |

两套交付还带 Multiwfn 2026.11.26 做波函数分析。它的源码只支持 Intel 编译器，所以安装的是作者发布的无图形界面程序，命令为 `Multiwfn`，算例文件在 `/usr/local/share/multiwfn/examples`。使用时按其许可引用原始论文。

第三套交付 `smp` 面向单台云主机，定位类似超算登录节点：提供日常功能和快速测试，不做大规模计算。它基于 CPU 基座，不装 MPI，带全部工具链、材料 Python 包、Wannier90、Packmol 和 Multiwfn，LAMMPS、Quantum ESPRESSO 和 CP2K 为多线程版。[SMP 交付配置](delivery/smp/.devcontainer/devcontainer.json)

应用的选项及默认值见各自的 `devcontainer-feature.json`。LAMMPS 始终启用 KSPACE，默认关闭 INTEL 和需联网下载代码的包。启用 `PLUMED`、`H5MD` 或 `NETCDF` 时需要对应 Feature。

两套交付都安装与 `wise-platform` 材料 CPU 清单同版本的 NumPy、SciPy、pandas、Matplotlib、ASE、pymatgen、spglib、Phonopy、Phono3py、PySCF、pycalphad、MDAnalysis 和 h5py。传递依赖按 Ubuntu 24.04 的 CPython 3.12／linux/amd64 锁定 wheel 和 SHA-256，验收包含离线导入及 HDF5 读写。[Python 依赖锁](applications/src/materials-python/requirements.txt)

两套交付默认设置 `--shm-size=16g`、`--cap-add=SYS_PTRACE` 和 `--ulimit memlock=-1:-1`。使用 InfiniBand/RoCE 时另加 `--device=/dev/infiniband --network=host`。GPUDirect RDMA 还需宿主机加载 `nvidia-peermem` 和 `gdrdrv`。OpenMP 默认将线程绑在相邻核心，每个 rank 默认 1 个线程。Feature 源码编译按可用 CPU 决定并行度，每个编译任务最多使用 32 个作业。

CUDA full 镜像面向 RTX PRO 5000 Blackwell（计算能力 12.0）。LAMMPS、QE、CP2K 和 ELPA 都编译 `sm_120`，离线验收检查四者的设备代码。设备验收要求 NVIDIA 驱动主版本至少为 575。[NVIDIA GPU 计算能力](https://developer.nvidia.com/cuda/gpus)

## 验收与基准

构建机权限、代理、Feature 测试和 CUDA 编译错误见 [镜像排障](../docs/troubleshooting.md)。

在有 Docker 和 Buildx 的构建机上运行分级 Feature 测试。

```bash
npm ci
npm test
npm run test:features -- cpu openmp
npm run test:features -- cpu packmol
npm run test:features -- cpu all
npm run test:features -- cuda all
```

### 真机自检

镜像部署到运行机器后，用 [自检目录](delivery/selftest/) 确认每个软件的最小算例都能跑通。自检不装进镜像，也不依赖本仓库的构建系统，CPU 和 CUDA 镜像共用。把 `delivery/selftest/` 整个目录拷到目标机器即可。

```bash
sh run-in-image.sh wise-compute:materials-cuda
sh run-in-image.sh wise-compute:materials-cpu lammps cp2k
```

脚本把目录只读挂进容器执行 `materials-selftest`，逐项输出 `PASS`、`FAIL` 或 `SKIP`、耗时和成功率，有失败时退出码为 1。各项输出和 `result.json` 写到当前目录的 `selftest-logs`。镜像里没有的软件记为 `SKIP`。

CUDA 镜像在宿主机有 GPU 时自动带 `--gpus all`，LAMMPS、Quantum ESPRESSO 和 CP2K 必须在输出中报告自己在 GPU 上计算，否则判失败。看不到 GPU 时设备相关的项记为 `SKIP`，加 `--require-gpu` 则判失败。核对显卡是否符合本交付的编译目标时设置 `SELFTEST_MIN_DRIVER=575 SELFTEST_GPU_CAPABILITY=12.0`。已在容器内时直接执行 `sh materials-selftest`。

构建机的 Feature 测试和完整镜像验收复用这些算例，另加只属于本仓库构建的检查。

Scenario 和断言脚本放在 `feature-tests/test/_global/`，遵循 Dev Container Feature Starter 的结构。`npm run test:features` 将各层的源码整理到临时 `src/`，再逐个调用官方 `devcontainer features test --global-scenarios-only`。断言通过 Dev Container CLI 提供的 `check` 和 `reportResults` 执行。[Feature Starter](https://github.com/devcontainers/feature-starter) · [官方测试文档](https://github.com/devcontainers/cli/blob/main/docs/features/test.md)

每个 scenario 使用交付配方锁定的基础镜像。首个 scenario 安装 Core 和 OpenMP，运行 C、C++ 和 Fortran 双线程归约。前置 scenario 通过后，再运行带有对应依赖的应用 scenario。可单独选择 `mpi`、`libraries`、`python`、`wannier90`、`lammps`、`quantum-espresso` 或 `cp2k`。算例以非 root 用户离线运行，校验数值和输出文件。`npm test` 检查所有本地 Feature 和两套交付的 Feature 选项均有 scenario 覆盖。`FEATURE_TEST_BASE_IMAGE` 可指定同一基础镜像的 Harbor 引用，`FEATURE_TEST_APT_SNAPSHOT=''` 可临时使用常规 APT 源。

构建时可用 `--base-image` 切到 Harbor 里的兼容上游镜像。CUDA 上游仍需提供 NVIDIA HPC SDK 25.7、CUDA 12.9 和 HPC-X。

```bash
npx wisehub image build --workspace-folder recipe/base/cpu --platform linux/amd64 \
  --base-image harbor.will/docker.io/library/ubuntu:24.04 --image wise-compute:base-cpu
```

在仓库根目录构建，并用同一套 Dev Container scenario 验收完整镜像。

```bash
npx wisehub image build --workspace-folder recipe/delivery/cpu --local-features recipe --platform linux/amd64 --image wise-compute:materials-cpu
npx wisehub image build --workspace-folder recipe/delivery/cuda --local-features recipe --platform linux/amd64 --image wise-compute:materials-cuda
npm run test:delivery -- cpu wise-compute:materials-cpu
npm run test:delivery -- cuda wise-compute:materials-cuda
FEATURE_TEST_GPU=1 npm run test:delivery -- cuda wise-compute:materials-cuda
```

完整镜像 scenario 检查工具、链接、互连、绑核和并行 I/O，并重跑 Feature 场景中的应用算例。CUDA 默认执行离线验收。在 GPU 节点设置 `FEATURE_TEST_GPU=1` 后，额外执行 LAMMPS、QE 和 CP2K 的设备算例。

CUDA 的 OpenMP 场景检查文件句柄、兼容驱动链接，以及 NVCC 和 nvfortran 生成的 `sm_120` 设备代码。LAMMPS 在全量编译前用自己的 NVCC wrapper 重跑链接检查，并把 CUDA 编译控制在 12 路并行。

[`benchmark.sh`](delivery/benchmark.sh) 在镜像内运行 LAMMPS 或给定的 QE/CP2K 算例，输出耗时、加速比和并行效率 CSV。用 `--hostfile` 测跨节点，用 `--threads` 设置每个 rank 的线程数，用 `--gpu` 测 KOKKOS。
