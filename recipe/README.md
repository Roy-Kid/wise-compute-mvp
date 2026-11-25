# 材料计算镜像配方

| 层 | 内容 |
| --- | --- |
| [base](base) | CPU 用 Ubuntu 24.04，CUDA 用 NVIDIA HPC SDK 25.7（CUDA 12.9）及 GDRCopy。基座锁定 digest，apt 使用 Ubuntu 快照。 |
| [infra](infra/src) | Feature SDK、编译器、MPI、互连、数学库和并行 I/O。 |
| [toolchains](toolchains/src) | Python、Conda、uv、Rust 和 Node.js。 |
| [applications](applications/src) | LAMMPS、Quantum ESPRESSO、CP2K、Wannier90、Packmol、材料 Python 工具、mpi4py 和可选的 PLUMED。 |
| [providers](providers/src) | 按服务器供应商选用的 SDK Feature。[`aliyun`](providers/src/aliyun) 目前只登记 Feature。 |
| [delivery](delivery) | CPU/CUDA Dev Container 配置、验收和基准脚本。 |

供应商 Feature 由交付配置的 `features` 显式选用。阿里云占位项的发布引用为 `harbor.will/wise/wise-compute-features/providers/aliyun:0`。

## 编写 Feature

每个 Feature 由 `devcontainer-feature.json` 和 `install.sh` 组成。元数据记录选项和依赖，安装脚本固定上游源版本并调用 [Feature SDK](infra/src/core/feature.sh)。

```sh
#!/bin/sh
set -eu
wise_id=example
. /opt/wise/lib/wise/feature.sh
wise_require_capability mpi
wise_require fftw
wise_require_if "${ELPA:-false}" elpa
# 安装到 $WISE_PREFIX，并用 wise_linked 检查链接。
wise_done
```

- 无条件依赖写入 `dependsOn`，条件依赖和能力提供者写入 `installsAfter`。依赖指向同层或下层，以 `harbor.will/wise/wise-compute-features/<层>/<id>:<主版本>` 引用。`npm test` 校验声明及两套交付的安装顺序。
- CPU 交付通过 Feature 安装 Open MPI，使用 UCX 和 libfabric。可选 MPICH 使用 libfabric。
- 基座通过 `WISE_BASE_<能力>` 声明已有能力。CUDA 设置 `WISE_BASE_MPI=openmpi` 和 `WISE_MPI_ROOT`，让 Feature 复用 SDK 自带的 HPC-X 和 UCX。重复选中 MPI 提供者会报错。使用 MPI 的 CUDA 版 Fortran 库按同一个 `nvfortran` ABI 构建。
- CUDA、NVIDIA HPC SDK 和 GDRCopy 由 CUDA 基座提供。CPU 指令集基线是 x86-64-v3，每个进程只加载一套 OpenMP 运行时。
- 修改 Feature 后递增其 `version`，升主版本时更新引用。发布和本地构建见 [CLI 用法](../docs/cli.md)。

## 交付配置

材料 CPU 完整镜像的应用名为 `materials-full`。在 `harbor.will/wise/wise-compute-image` 使用 `<app>-<variant>-<version>` 标签。开发候选版使用 SemVer 的 `-dev.N` 后缀，正式版使用 `MAJOR.MINOR.PATCH`。构建输入、镜像版本和各应用版本见 [Lavas 发布配方](delivery/cpu/lavas-release.json)。

| 应用 | CPU | CUDA |
| --- | --- | --- |
| LAMMPS | MPI、OPENMP、FFTW3、H5MD、NETCDF | 加 KOKKOS（`AMPERE80`）和 cuFFT |
| Quantum ESPRESSO | GCC、MPI、OpenMP、ScaLAPACK、ELPA、HDF5 | nvfortran、OpenACC、GPU-aware MPI，目标为 A100 和 H100 |
| CP2K | ELPA、HDF5、`largeSystems` | 同样启用 ELPA、HDF5 和 `largeSystems`，使用 NVHPC 构建 A100 版 |

应用的选项及默认值见各自的 `devcontainer-feature.json`。LAMMPS 始终启用 KSPACE，默认关闭 INTEL 和需联网下载代码的包。启用 `PLUMED`、`H5MD` 或 `NETCDF` 时需要对应 Feature。

两套交付都安装与 `wise-platform` 材料 CPU 清单同版本的 NumPy、SciPy、pandas、Matplotlib、ASE、pymatgen、spglib、Phonopy、Phono3py、PySCF、pycalphad、MDAnalysis 和 h5py。传递依赖按 Ubuntu 24.04 的 CPython 3.12／linux/amd64 锁定 wheel 和 SHA-256，验收包含离线导入及 HDF5 读写。[Python 依赖锁](applications/src/materials-python/requirements.txt)

两套交付默认设置 `--shm-size=16g`、`--cap-add=SYS_PTRACE` 和 `--ulimit memlock=-1:-1`。使用 InfiniBand/RoCE 时另加 `--device=/dev/infiniband --network=host`。GPUDirect RDMA 还需宿主机加载 `nvidia-peermem` 和 `gdrdrv`。OpenMP 默认将线程绑在相邻核心，每个 rank 默认 1 个线程。

CUDA 交付验收要求 NVIDIA 驱动主版本至少为 575。交付主要针对 A100，可为 H100 单独配置 LAMMPS 的 `gpuArch: HOPPER90`、QE 的 `cudaCC: 90`、`cp2k-toolchain` 的 `gpuVersion: H100` 和 ELPA 的 `cudaArch: 90`。

## 验收与基准

构建时可用 `--base-image` 切到 Harbor 里的兼容上游镜像。CUDA 上游仍需提供 NVIDIA HPC SDK 25.7、CUDA 12.9 和 HPC-X。

```bash
npx wisehub image build --workspace-folder recipe/base/cpu --platform linux/amd64 \
  --base-image harbor.will/docker.io/library/ubuntu:24.04 --image wise-compute:base-cpu
```

在仓库根目录构建并在 GPU 节点验收 CUDA 交付。

```bash
npx wisehub image build --workspace-folder recipe/delivery/cuda --local-features recipe --platform linux/amd64 --image wise-compute:materials-cuda
docker run --rm -i --gpus 1 --shm-size=16g --user 65534:65534 --network none --tmpfs /tmp:mode=1777 \
  --entrypoint /bin/sh wise-compute:materials-cuda -s cuda < recipe/delivery/verify.sh
```

[`verify.sh`](delivery/verify.sh) 检查工具、链接、互连、绑核、并行 I/O 和 LAMMPS 数值一致性。CPU 版传入 `cpu`，并省略 `--gpus`。无 GPU 的 CI 以 `WISE_VERIFY_GPU=0` 跳过 CUDA 设备验收。

[`benchmark.sh`](delivery/benchmark.sh) 在镜像内运行 LAMMPS 或给定的 QE/CP2K 算例，输出耗时、加速比和并行效率 CSV。用 `--hostfile` 测跨节点，用 `--threads` 设置每个 rank 的线程数，用 `--gpu` 测 KOKKOS。
