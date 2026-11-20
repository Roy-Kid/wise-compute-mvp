# stack

五层分级。上层只依赖下层；Feature 之间的依赖由各自 `devcontainer-feature.json` 的 `dependsOn` 声明，Dev Container CLI 据此拉入并排序。Feature 之间、交付与 Feature 之间只用注册表引用 `harbor.will/willmat/wise/<层>/<id>:<主版本>`，仓库内没有本地链接。

| 层 | 目录 | 内容 |
| --- | --- | --- |
| 1. 系统基座 | [`base/{cpu,cuda}`](base) | CPU：`ubuntu:24.04`。CUDA：`nvcr.io/nvidia/nvhpc:25.7-devel-cuda12.9-ubuntu24.04`（NVIDIA HPC SDK）。均锁定 digest，apt 固定到 Ubuntu 快照 |
| 2. infra | [`infra/src`](infra/src) | `openmp`（GCC、gfortran、CMake、OpenMP）、`openmpi`、`mpich`、`linear-algebra`（OpenBLAS、FFTW）、`scalapack` |
| 3. 工具链 | [`toolchains/src`](toolchains/src) | `python`、`conda`、`uv`、`rust`、`nodejs` |
| 4. 科学应用 | [`applications/src`](applications/src) | `numpy`、`mpi4py`、`lammps`、`quantum-espresso`、`cp2k`、`wannier90`、`packmol` |
| 5. 最终交付 | [`delivery/{cpu,cuda}`](delivery) | 标准 Dev Container 工作区：以对应基座的 Dockerfile 构建，按注册表引用选择各层 Feature；[`verify.sh`](delivery/verify.sh) 验收，[`release-record.mjs`](delivery/release-record.mjs) 写发布记录 |

## 规则

由 [`test/stack.test.ts`](test/stack.test.ts) 检查（`npm test`，离线，以 `--local-features` 同样的方式解析）：

- **依赖方向**：`dependsOn` / `installsAfter` 只能指向同层或下层，且是本仓库 Feature 的注册表引用，主版本与源码一致。
- **NVIDIA 只来自基座**：HPC SDK、CUDA 及一切 NVIDIA 相关处理只在 [`base/cuda`](base/cuda/.devcontainer/Dockerfile) 中完成，包括移除 SDK 自带的 HPC-X MPI、移除 NVIDIA apt 源、导出 `NVHPC_ROOT` 与 `CUDA_HOME`。Feature 不安装、不硬编码任何 NVIDIA 路径，只读这两个变量；应用的 GPU 选项在没有 CUDA 基座时直接失败。
- **一个 MPI**：每个交付只选一个 MPI Feature（默认 `openmpi`，CUDA 基座上为 CUDA-aware）。MPI 是二选一，需要 MPI 的 Feature 用 `installsAfter` 排在其后并在安装时检查。
- **自检链接**：每个源码 Feature 装完后用 `ldd` 确认链接的是下层提供的库（例如 `lmp` 链接 `/opt/wise/lib` 的 libmpi、libfftw3，GPU 版链接 SDK 的 cuFFT）。
- **源码锁定**：源码包校验 SHA256；git 来源按 commit 只拉取该提交（`fetch --depth 1`），子模块同样只拉一层。Python 包按哈希安装。
- Feature 的 `id` 与目录名一致，`install.sh` 为 `#!/bin/sh` + `set -eu`。

## 发布与引用

infra、toolchains、applications 三个集合发布到 Harbor，每个 Feature 的引用为 `harbor.will/willmat/wise/<层>/<id>:<版本>`；`dependsOn`、`installsAfter` 和交付配置都按主版本引用（例如 `:1`），交付构建时由官方 CLI 写出 `devcontainer-lock.json` 锁定 digest。

```bash
npx wisehub feature publish stack --registry harbor.will --namespace willmat/wise   # infra → toolchains → applications
npx wisehub image build --workspace-folder stack/delivery/cpu --platform linux/amd64 --image wise-compute:materials-cpu
```

开发和 MR 不必先发布：`--local-features stack` 在构建时把指向本仓库的引用临时换成源码副本，构建后删除。

```bash
npx wisehub image build --workspace-folder stack/delivery/cpu --local-features stack --platform linux/amd64 --image wise-compute:materials-cpu
```

修改 Feature 时提升其 `version`；改了主版本，同时更新所有引用它的 `:<主版本>`（测试会检查引用与源码版本一致）。已发布的版本不会被覆盖。

## 交付

| | CPU | CUDA |
| --- | --- | --- |
| 基座 | Ubuntu 24.04 | NVIDIA HPC SDK 25.7（CUDA 12.9；宿主机驱动需满足镜像声明的 `NVIDIA_REQUIRE_CUDA`） |
| LAMMPS | MPI + OPENMP | 另加 KOKKOS（`AMPERE80`），cuFFT |
| Quantum ESPRESSO | GCC，ScaLAPACK | nvfortran + OpenACC，cuFFT、cuSOLVER（`cudaCC: 80`） |
| CP2K | CPU | CUDA（`gpuVersion: A100`） |

```bash
npx wisehub image build --workspace-folder stack/delivery/cuda --local-features stack --platform linux/amd64 --image wise-compute:materials-cuda
docker run --rm -i --gpus 1 --user 65534:65534 --network none --tmpfs /tmp:mode=1777 \
  --entrypoint /bin/sh wise-compute:materials-cuda -s cuda < stack/delivery/verify.sh
```

## 版本

| 组件 | 版本 | 来源 |
| --- | --- | --- |
| Open MPI / MPICH | 5.0.11 / 4.3.2 | 源码包 + SHA256 |
| FFTW / ScaLAPACK | 3.3.11 / 2.2.3 | 源码包 + SHA256 |
| OpenBLAS | Ubuntu 24.04（OpenMP 版） | apt 快照 |
| LAMMPS | stable_30Sep2026_update1 | git commit |
| Quantum ESPRESSO | 7.6 | git commit（含 mbd、devxlib 子模块） |
| CP2K | 2026.2 | git commit；libxc、libint、libxsmm、DBCSR 由 CP2K toolchain 校验下载 |
| Wannier90 / Packmol | 3.1.0 / 21.2.3 | git commit |
| NumPy / mpi4py | 2.5.5 / 4.1.2 | pip 哈希（mpi4py 从 sdist 编译） |
