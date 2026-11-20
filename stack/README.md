# stack

五层分级。上层只依赖下层；Feature 之间的依赖由各自 `devcontainer-feature.json` 的 `dependsOn` 声明，Dev Container CLI 据此拉入并排序。Feature 之间、交付与 Feature 之间只用注册表引用 `harbor.will/willmat/wise/<层>/<id>:<主版本>`，仓库内没有本地链接。

| 层 | 目录 | 内容 |
| --- | --- | --- |
| 1. 系统基座 | [`base/{cpu,cuda}`](base) | CPU：`ubuntu:24.04`。CUDA：`nvcr.io/nvidia/nvhpc:25.7-devel-cuda12.9-ubuntu24.04`（NVIDIA HPC SDK）。均锁定 digest，apt 固定到 Ubuntu 快照 |
| 2. infra | [`infra/src`](infra/src) | 契约：`core`（`/opt/wise` 前缀、Feature SDK、安装登记表，所有 Feature 都依赖它）。编译：`openmp`（GCC、gfortran、CMake，x86-64-v3 基线，绑核默认值）。互连：`rdma`（rdma-core）、`ucx`、`libfabric`。MPI：`openmpi`、`mpich`。数学：`linear-algebra`（OpenBLAS）、`fftw`（双/单精度，MPI + OpenMP，所有 CPU 侧 FFT）、`scalapack`、`elpa`。并行 I/O：`hdf5`、`netcdf` |
| 3. 工具链 | [`toolchains/src`](toolchains/src) | `python`、`conda`、`uv`、`rust`、`nodejs` |
| 4. 科学应用 | [`applications/src`](applications/src) | `numpy`、`mpi4py`、`lammps`、`quantum-espresso`、`cp2k`、`wannier90`、`packmol`；可选的第三方库 `plumed` |
| 5. 最终交付 | [`delivery/{cpu,cuda}`](delivery) | 标准 Dev Container 工作区：以对应基座的 Dockerfile 构建，按注册表引用选择各层 Feature；[`verify.sh`](delivery/verify.sh) 验收，[`release-record.mjs`](delivery/release-record.mjs) 写发布记录 |

## Feature 的写法

每个 Feature 是一个目录：`devcontainer-feature.json`（元数据、选项、`dependsOn` / `installsAfter`）加 `install.sh`。`install.sh` 统一使用 `core` 提供的 SDK [`feature.sh`](infra/src/core/feature.sh)：

```sh
#!/bin/sh
set -eu
. /opt/wise/lib/wise/feature.sh <id>        # 第一行：以自己的 id 载入 SDK

wise_require_capability mpi                # 需要某个能力（openmpi 或 mpich 提供），不关心是谁
wise_require fftw                          # 无条件需要某个 Feature        → 写进 dependsOn
wise_require_if "${ELPA:-false}" elpa      # 布尔选项为 true 时才需要      → 写进 installsAfter
wise_workdir                               # 临时目录 $WISE_WORK，退出时删除
wise_fetch_tar URL SHA256 "$WISE_WORK/src" # 或 wise_fetch_git URL COMMIT DIR [子模块…|--all]
...                                        # 构建，安装到 $WISE_PREFIX
wise_linked "$WISE_PREFIX/bin/x" "$WISE_PREFIX/lib/libmpi"   # 自检链接
wise_done                                  # 最后一行：登记为已安装
```

- **解耦**：Feature 之间只通过登记表按 id 或能力询问（`wise_require*`、`wise_provider mpi`），不探测别人的文件；独占能力用 `wise_provide`（两个 MPI 同时安装即失败）。换掉一个 Feature 的实现，只要 id 与能力不变，使用者不受影响。
- **单一来源**：依赖只在 `install.sh` 的 `wise_require*` 中声明一次。`npm test` 读取这些调用，检查 `dependsOn`（无条件依赖）、`installsAfter`（条件依赖、能力提供者，不得有多余项）与之一致，并按两份交付的实际安装顺序和选项值逐条核对。
- **可组合**：交付只列出想要的 Feature 和选项，其余由 `dependsOn` 拉入、`installsAfter` 排序；缺了条件依赖（例如打开 `elpa` 却没装 `elpa` Feature），`npm test` 和构建都会报出缺什么。
- **公共逻辑只在 SDK**：下载与校验、只拉一个 commit、apt 快照安装、链接自检、nvfortran 构建环境（`wise_nvfortran_env`）。新增 Feature 时先看 SDK 有没有，没有再加到 SDK 里，而不是在 `install.sh` 里另写。

## 规则

由 [`test/stack.test.ts`](test/stack.test.ts) 检查（`npm test`，离线，以 `--local-features` 同样的方式解析）：

- **依赖方向**：`dependsOn` / `installsAfter` 只能指向同层或下层，且是本仓库 Feature 的注册表引用，主版本与源码一致。
- **NVIDIA 只来自基座**：HPC SDK、CUDA 及一切 NVIDIA 相关处理只在 [`base/cuda`](base/cuda/.devcontainer/Dockerfile) 中完成，包括移除 SDK 自带的 HPC-X MPI、移除 NVIDIA apt 源、编译 GDRCopy 用户库，导出 `NVHPC_ROOT`、`CUDA_HOME` 与 `GDRCOPY_HOME`。Feature 不安装、不硬编码任何 NVIDIA 路径，只读这三个变量；应用的 GPU 选项在没有 CUDA 基座时直接失败。
- **一个 MPI，一套互连**：每个交付只选一个 MPI Feature，二者都以 `wise_provide mpi` 声明独占能力，使用者只写 `wise_require_capability mpi`。`openmpi`（默认）走 UCX（InfiniBand/RoCE，CUDA 基座上 CUDA-aware 且经 GDRCopy 做 GPUDirect RDMA）和 OFI；`mpich` 走 ch4:ofi（libfabric）。二者都建在 `rdma`（rdma-core）上，PMIx 内置，`mpirun` 独立可用，Slurm 下 `srun --mpi=pmix`。
- **一个 CPU 基线**：`openmp` Feature 以 `CFLAGS`/`CXXFLAGS`/`FFLAGS`/`FCFLAGS` 统一设定 `-march=x86-64-v3`（AVX2、FMA，Haswell 及以后）；nvfortran 对应 `-tp=haswell`（`wise_nvfortran_env`），CP2K toolchain 对应 `--target-cpu=haswell`。FFTW、OpenBLAS 在运行时再选 AVX-512 内核。其他取值被测试拒绝。
- **每个进程一个 OpenMP 运行时**：GCC 编译的程序用 libgomp；QE GPU 版用 nvfortran、关闭 OpenMP，只链接 SDK 的 BLAS/LAPACK 和 `/opt/wise/nvhpc` 下的 nvfortran 版 ScaLAPACK、ELPA、HDF5（CUDA 基座上这三个 Feature 额外编译这一份，因为 Fortran 模块与编译器绑定）。安装和验收都检查不会同时加载 libgomp 与 libnvomp。
- **自检链接**：每个源码 Feature 装完后用 `ldd` 确认链接的是下层提供的库（例如 `lmp` 链接 `/opt/wise/lib` 的 libmpi、libfftw3，GPU 版链接 SDK 的 cuFFT）。
- **源码锁定**：源码包校验 SHA256；git 来源按 commit 只拉取该提交（`fetch --depth 1`），子模块同样只拉一层。Python 包按哈希安装。
- Feature 的 `id` 与目录名一致，`install.sh` 为 `#!/bin/sh` + `set -eu` + 载入 SDK，以 `wise_done` 结束。

## 应用的构建配置

计算软件默认编译**全部自带的 package，不编译需要第三方库的 package，联网下载第三方代码的 package 一律默认关闭**。

LAMMPS 的选项：

| 选项 | 默认 | 作用 |
| --- | --- | --- |
| `variant` | `cpu` | `cpu`：MPI + OPENMP package。`cuda`：另加 KOKKOS（CUDA 后端，宿主侧 OpenMP），需 CUDA 基座；原生 GPU package 从不编译 |
| `gpuArch` | `AMPERE80` | `cuda` 版的 Kokkos GPU 架构（`VOLTA70`、`AMPERE80`、`AMPERE86`、`ADA89`、`HOPPER90`），每次构建一个；同时嵌入 PTX，更新的 GPU 首次启动时 JIT 编译后可运行（未针对其优化） |
| `potentials` | `bundled` | `none`：不装势函数；`bundled`：装 LAMMPS 源码自带的势函数；`all`：再下载已启用 package 登记的大势函数文件（download.lammps.org，LAMMPS 按 SHA256 校验）。路径为 `LAMMPS_POTENTIALS` |
| `extraPackages` | 空 | 额外开启的 package，如 `PLUMED`、`H5MD`、`NETCDF`、`COMPRESS`；`cpu` 版可加回 `INTEL` |
| `disablePackages` | 空 | 关闭自带 package，如 `MGPT`；KSPACE 不可关闭 |
| `cmakeArgs` | 空 | 追加的 CMake 参数，最后生效；以下检查仍然适用 |

- KSPACE 必选，FFT 固定为 `fftw` Feature 的 FFTW3（含 OpenMP 线程库）；`cuda` 版 KOKKOS 的 FFT 走 cuFFT，宿主侧仍是 FFTW3。
- 默认集合是 LAMMPS 自带的 CMake 预设 `all_on` + `nolib`，再关掉 INTEL（只有配合 Intel 编译器才有收益）和 [`lammps/install.sh`](applications/src/lammps/install.sh) 中 `downloading` 列出的联网下载 package（KIM、MACHDYN、MBX、MDI、ML-HDNNP、ML-PACE、ML-QUIP、ML-RUNNER、PLUMED、SCAFACOS、VORONOI，取自所锁定 commit 的 `cmake/Modules/Packages`）以及势函数文件下载（`DOWNLOAD_POTENTIALS`）。
- 由 Feature 提供库的 package 在 `providers=` 一行登记（`PLUMED:plumed H5MD:hdf5 NETCDF:netcdf`），提供者列入 lammps 的 `installsAfter`，请求时经 `wise_require` 检查已安装。`downloading` 中没有提供者的 package 不可开启。其余 package（如需要系统库的 `COMPRESS`）直接开启。
- CMake 配置后按实际缓存再查一次（包括经 `cmakeArgs` 改动的）：KSPACE 开且 FFT 为 FFTW3；GPU package 关；`cuda` 版 KOKKOS + CUDA 开、`cpu` 版 KOKKOS 关；`downloading` 及有提供者的 package 中已开启的都有提供者 Feature；除 `potentials=all` 的 `DOWNLOAD_POTENTIALS` 外没有任何 `DOWNLOAD_*` 为开。任一不满足即失败。
- `npm test` 检查：提供者列入 `installsAfter`；两份交付请求的 package 都带有提供者 Feature，且其安装早于 lammps。

例：CPU 交付加 PLUMED，在 `delivery/cpu/.devcontainer/devcontainer.json` 中写

```jsonc
"harbor.will/willmat/wise/applications/plumed:1": {},
"harbor.will/willmat/wise/applications/lammps:2": { "extraPackages": "PLUMED" },
```

Quantum ESPRESSO 与 CP2K 的选项：

| Feature | 选项 | 默认 | 作用 |
| --- | --- | --- | --- |
| quantum-espresso | `cudaCC` | 空 | GPU 版的计算能力，逗号分隔可多架构（`80,90`）；GPU 版开启 GPU-aware MPI，每卡一个 rank，无 OpenMP |
| | `elpa`、`hdf5` | `false` | 使用 `elpa`、`hdf5` Feature |
| cp2k | `gpuVersion` | 空 | CP2K GPU 目标（`V100`、`A100`、`H100`），嵌入 PTX |
| | `elpa`、`hdf5` | `false` | 使用 `elpa`、`hdf5` Feature |
| | `largeSystems` | `false` | 由 CP2K toolchain 编译 COSMA、SpFFT、SpLA、SIRIUS、spglib、libvori（需 `hdf5`） |
| 两者 | `cmakeArgs` | 空 | 追加的 CMake 参数 |

QE 默认编译全部自带程序，不开第三方库。CP2K 的 libxc、libint、libxsmm、DBCSR 是其构建前提，与 `largeSystems` 的库一样由 CP2K 自带 toolchain 校验下载。

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
| 基座 | Ubuntu 24.04 | NVIDIA HPC SDK 25.7（CUDA 12.9）+ GDRCopy 2.7 |
| MPI | Open MPI：UCX + OFI，PMIx | 同左，CUDA-aware，GPUDirect RDMA |
| LAMMPS | `variant: cpu`：MPI + OPENMP，KSPACE 走 FFTW3，H5MD、NETCDF | `variant: cuda`：另加 KOKKOS（`AMPERE80`），KOKKOS 的 FFT 走 cuFFT |
| Quantum ESPRESSO | GCC，MPI + OpenMP，ScaLAPACK、ELPA、HDF5 | nvfortran + OpenACC（`cudaCC: 80,90`），cuFFT、cuSOLVER，GPU-aware MPI，nvfortran 版 ScaLAPACK、ELPA、HDF5 |
| CP2K | ELPA、HDF5、COSMA、SpFFT、SpLA、SIRIUS | CUDA（`gpuVersion: A100`），同左 |

运行要求：

- **容器参数**：`--shm-size=16g`（或 `--ipc=host`），`--cap-add=SYS_PTRACE`（同节点 rank 间单次拷贝 CMA），`--ulimit memlock=-1`。交付配置的 `runArgs` 已带上；`verify.sh` 要求 `/dev/shm` 至少 1 GiB。
- **InfiniBand/RoCE**：另加 `--device=/dev/infiniband --network=host`；GPUDirect RDMA 需要宿主机加载 `nvidia-peermem` 与 `gdrdrv`，没有时 UCX 自动退回经主机内存中转。
- **绑核**：默认 `OMP_PLACES=cores`、`OMP_PROC_BIND=close`、`OMP_NUM_THREADS=1`。混合并行例：`mpirun -n 8 --map-by slot:PE=4 --bind-to core -x OMP_NUM_THREADS=4 lmp -sf omp -pk omp 4 -in in.lammps`。
- **GPU 驱动**：CUDA 12.9 原生需要 575 及以上驱动；更老的驱动只有数据中心 GPU 可经前向兼容包运行（`verify.sh` 中以 `WISE_CUDA_COMPAT=1` 放行），消费级 GPU 必须升级驱动。
- **GPU 架构**：镜像针对 A100（sm_80）优化。QE 另含 H100（sm_90）代码；Kokkos、CP2K、ELPA 嵌入 sm_80 PTX，H100 上 JIT 后可运行但未专门优化。H100 集群应以 `gpuArch: HOPPER90`、`cudaCC: 90`、`gpuVersion: H100`、`elpa.cudaArch: 90` 另出一份交付。

```bash
npx wisehub image build --workspace-folder stack/delivery/cuda --local-features stack --platform linux/amd64 --image wise-compute:materials-cuda
docker run --rm -i --gpus 1 --shm-size=16g --user 65534:65534 --network none --tmpfs /tmp:mode=1777 \
  --entrypoint /bin/sh wise-compute:materials-cuda -s cuda < stack/delivery/verify.sh
```

验收（`verify.sh`）除工具与链接外还检查：互连组件、`/dev/shm`、绑核、FFTW 双/单精度、并行 HDF5/NetCDF、QE/CP2K 链接 ELPA 等库、每进程单一 OpenMP 运行时，LAMMPS 在 1 与 2 个 rank 下能量一致（相对误差 ≤ 1e-8），H5MD/NETCDF 轨迹写出；CUDA 版另查 CUDA-aware MPI、UCX CUDA 传输、驱动版本，并在 GPU 上运行。

扩展性基准（`benchmark.sh`）：在镜像内以 1、2、4… 个 rank 跑 LAMMPS LJ（25.6 万原子）与 PPPM，或给定的 QE/CP2K 输入（如 AUSURF112、H2O-64），输出 CSV（耗时、加速比、并行效率）；`--hostfile` 跨节点，`--threads` 混合并行，`--gpu` 用 KOKKOS。

```bash
docker run --rm -i --shm-size=16g --entrypoint /bin/sh wise-compute:materials-cpu -s -- --ranks "1 2 4 8" lammps-lj lammps-pppm < stack/delivery/benchmark.sh
```

所有源码组件以去除调试符号的方式安装；CI 在 `image.txt` 中记录镜像大小。

## 版本

| 组件 | 版本 | 来源 |
| --- | --- | --- |
| GDRCopy（CUDA 基座） | 2.7 | git commit |
| rdma-core、OpenBLAS（OpenMP 版） | Ubuntu 24.04 | apt 快照 |
| UCX / libfabric | 1.21.1 / 2.7.0 | 源码包 + SHA256 |
| Open MPI / MPICH | 5.0.11 / 4.3.2 | 源码包 + SHA256 |
| FFTW / ScaLAPACK / ELPA | 3.3.11 / 2.2.3 / 2026.02.002 | 源码包 + SHA256 |
| HDF5 / NetCDF-C | 2.2.0 / 4.10.1 | 源码包 + SHA256 |
| PLUMED（可选） | 2.10.2 | 源码包 + SHA256 |
| LAMMPS | stable_30Sep2026_update1 | git commit |
| Quantum ESPRESSO | 7.6 | git commit（含 mbd、devxlib 子模块） |
| CP2K | 2026.2 | git commit；libxc、libint、libxsmm、DBCSR 及 `largeSystems` 的库由 CP2K toolchain 校验下载 |
| Wannier90 / Packmol | 3.1.0 / 21.2.3 | git commit |
| NumPy / mpi4py | 2.5.5 / 4.1.2 | pip 哈希（mpi4py 从 sdist 编译） |
