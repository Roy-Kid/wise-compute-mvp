# 材料计算镜像配方

镜像由一个基座和一组 Dev Container Feature 组成。Feature 按层放在各自的目录里，上层只依赖同层或下层；交付配置从中选出一组，构建成一个镜像。

| 层 | 内容 |
| --- | --- |
| [base](base) | CPU 用 Ubuntu 24.04，CUDA 用 NVIDIA HPC SDK 25.7（CUDA 12.9）及 GDRCopy。基座锁定 digest，apt 使用 Ubuntu 快照。 |
| [infra](infra/src) | [Feature SDK](../docs/feature-sdk.md)（`core`）、编译器、MPI、互连、数学库和并行 I/O。 |
| [toolchains](toolchains/src) | Python、Conda、uv、Rust 和 Node.js。 |
| [applications](applications/src) | LAMMPS、Quantum ESPRESSO、CP2K、Wannier90、Packmol、Multiwfn、材料 Python 工具、mpi4py、可选的 PLUMED，以及 [ASE 支持的其他开源计算程序](#ase-计算器)。 |
| [providers](providers/src) | 按服务器供应商选用的 SDK Feature。[`aliyun`](providers/src/aliyun) 目前只登记 Feature，发布引用为 `harbor.will/wise/wise-compute-features/providers/aliyun:1`。 |
| [delivery](delivery) | 四套交付配置、[平台 SSH 入口](delivery/compute/README.md)、[真机自检](delivery/selftest)和基准脚本。 |
| [feature-tests](feature-tests) | 场景测试、完整镜像验收用的检查和 SDK 的单元测试。 |

怎么测试、构建和交付见[发布流程](../docs/release.md)，遇到过的问题见[排障记录](../docs/troubleshooting.md)。

## 编写 Feature

每个 Feature 由 `devcontainer-feature.json` 和 `install.sh` 组成。元数据记录选项和依赖；安装脚本固定上游源码的提交或校验和，用 [Feature SDK](../docs/feature-sdk.md) 的函数下载、查询镜像和检查结果。脚本的形状、函数表和 `wisehub feature check` 的规则都在那份文档里，这里只列配方层面的约定。

- **依赖。** 无条件依赖只写入 `dependsOn`。脚本查询的条件依赖、可选依赖和能力提供者写入 `installsAfter`。引用写成 `harbor.will/wise/wise-compute-features/<层>/<id>:<主版本>`。
- **版本。** 修改 Feature 后递增它的 `version`，升主版本时更新所有引用。已发布的版本不会被覆盖。
- **测试。** 每个 Feature 至少有一个场景，交付里用到的每个选项也要被某个场景覆盖；`npm test` 检查这两点。能独立运行的最小算例放进[自检](delivery/selftest)，场景测试和真机自检共用。

各 Feature 共同遵守的构建约定：

- **MPI。** CPU 交付通过 Feature 安装 Open MPI，使用 UCX 和 libfabric；可选的 MPICH 使用 libfabric。一个镜像只能有一个 MPI 提供者。CUDA 基座通过 `WISE_BASE_MPI=openmpi` 和 `WISE_MPI_ROOT` 声明自带的 HPC-X，Feature 直接复用；使用 MPI 的 CUDA 版 Fortran 库按同一个 `nvfortran` ABI 构建。
- **CUDA 版 CP2K 是例外。** 它需要 gfortran（nvfortran 编不过 DBCSR），而 HPC-X 只提供 nvfortran 的 MPI Fortran 模块，所以 CP2K 的工具链在 `/usr/local/cp2k-deps` 自建一套 GNU 依赖和 Open MPI。这套依赖不进默认 `PATH` 和动态库缓存，`cp2k.psmp` 等命令自行设置环境，并行运行用 `cp2k-mpirun`；用镜像的 `mpirun` 启动会被拒绝。
- **没有 MPI 的镜像。** FFTW、LAMMPS、Quantum ESPRESSO 和 CP2K 自动构建为多线程程序（`lmp`、`pw.x`、`cp2k.ssmp`），OpenMP 和 OpenBLAS（包括 NumPy、SciPy 自带的那份）默认用满所有核。有 MPI 时由 MPI 提供者设置 `OMP_NUM_THREADS=1` 和 `OPENBLAS_NUM_THREADS=1`，即每个进程一个线程。ScaLAPACK、ELPA、并行 HDF5 和 NetCDF、mpi4py 以及 CP2K 的 `largeSystems` 都需要 MPI。
- **指令集和编译器。** CPU 指令集基线是 x86-64-v3，每个进程只加载一套 OpenMP 运行时。CUDA、NVIDIA HPC SDK 和 GDRCopy 由 CUDA 基座提供。源码编译按可用 CPU 决定并行度，最多 32 个作业。

## 交付配置

材料 CPU 完整镜像的应用名为 `materials-full`。在 `harbor.will/wise/wise-compute-image` 使用 `<app>-<variant>-<version>` 标签。开发候选版使用 SemVer 的 `-dev.N` 后缀，正式版使用 `MAJOR.MINOR.PATCH`。构建输入、镜像版本和各应用版本见 [Lavas 发布配方](delivery/cpu/lavas-release.json)，各版本的差别见[发布流程](../docs/release.md#版本号)。用 Feature SDK 4 构建的镜像里，`wise-features` 列出装入的 Feature 及其版本。

CPU 和 CUDA 完整镜像的最后一层是[平台 SSH 入口](delivery/compute/README.md)：镜像以 `compute`（1000:1000）启动 2222 端口的 sshd，不再以 shell 作为入口，SSH 会话带有镜像的全部环境变量。0.1.0-dev.2 起的版本包含这一层。

| 应用 | CPU | CUDA |
| --- | --- | --- |
| LAMMPS | MPI、OPENMP、FFTW3、H5MD、NETCDF | 加 KOKKOS（`BLACKWELL120`）和 cuFFT |
| Quantum ESPRESSO | GCC、MPI、OpenMP、ScaLAPACK、ELPA、HDF5 | nvfortran、OpenACC、GPU-aware MPI，编译 `sm_120` |
| CP2K | ELPA、HDF5、`largeSystems` | 使用 GCC 和 CUDA 构建，启用 ELPA、HDF5 和 `largeSystems`，编译 `sm_120`；运行在自带的 GNU 栈和 Open MPI 上，用 `cp2k-mpirun` 启动 |

两套交付还带 Multiwfn 2026.11.26 做波函数分析。它的源码只支持 Intel 编译器，所以安装的是作者发布的无图形界面程序，命令为 `Multiwfn`，算例文件在 `/usr/local/share/multiwfn/examples`。使用时按其许可引用原始论文。

第三套交付 `smp` 面向单台云主机，定位类似超算登录节点：提供日常功能和快速测试，不做大规模计算。它基于 CPU 基座，不装 MPI，带全部工具链、材料 Python 包、Wannier90、Packmol 和 Multiwfn，LAMMPS、Quantum ESPRESSO 和 CP2K 为多线程版。[SMP 交付配置](delivery/smp/.devcontainer/devcontainer.json)

应用的选项及默认值见各自的 `devcontainer-feature.json`。LAMMPS 始终启用 KSPACE，默认关闭 INTEL 和需联网下载代码的包。启用 `PLUMED`、`H5MD` 或 `NETCDF` 时需要对应 Feature。

两套交付都安装与 `wise-platform` 材料 CPU 清单同版本的 NumPy、SciPy、pandas、Matplotlib、ASE、pymatgen、spglib、Phonopy、Phono3py、PySCF、pycalphad、MDAnalysis 和 h5py。传递依赖按 Ubuntu 24.04 的 CPython 3.12／linux/amd64 锁定 wheel 和 SHA-256，验收包含离线导入及 HDF5 读写。[Python 依赖锁](applications/src/materials-python/requirements.txt)

两套交付默认设置 `--shm-size=16g`、`--cap-add=SYS_PTRACE` 和 `--ulimit memlock=-1:-1`。使用 InfiniBand/RoCE 时另加 `--device=/dev/infiniband --network=host`。GPUDirect RDMA 还需宿主机加载 `nvidia-peermem` 和 `gdrdrv`。OpenMP 默认将线程绑在相邻核心，每个 rank 默认 1 个线程。

CUDA full 镜像面向 RTX PRO 5000 Blackwell（计算能力 12.0）。LAMMPS、QE、CP2K 和 ELPA 都编译 `sm_120`，离线验收检查四者的设备代码。设备验收要求 NVIDIA 驱动主版本至少为 575。[NVIDIA GPU 计算能力](https://developer.nvidia.com/cuda/gpus)

## ASE 计算器

[ASE 支持的计算器列表](https://ase.gitlab.io/ase/)里可自由再分发的开源程序各有一个 Feature，交付配置按需选用，三套现有交付都没有加入。CPU 和 CUDA 基座共用同一个 Feature：有 GPU 版本的程序用 `variant` 选项切换，`cpu` 是默认值，`cuda` 需要 CUDA 基座；没有 GPU 版本的程序没有这个选项，在两种基座上装的是同一个程序。

| Feature | 版本 | 安装内容 | `variant: cuda` |
| --- | --- | --- | --- |
| [gromacs](applications/src/gromacs) | 2026.4 | `gmx`（thread-MPI），镜像有 MPI 时另有 `gmx_mpi`；AVX2、FFTW、OpenBLAS | 非键、PME、成键和积分在 GPU 上，cuFFT |
| [gpaw](applications/src/gpaw) | 25.7.0 | Python 包和 PAW 数据集；Libxc、FFTW、MPI、ScaLAPACK | CUDA 内核和 CuPy，`cudaArch` 选计算能力 |
| [abacus](applications/src/abacus) | 3.10.1 | `abacus`（平面波和数值原子轨道）；MPI、ELPA、ScaLAPACK、Libxc，测试集的赝势和轨道在 `/usr/local/share/abacus/PP_ORB` | CUDA 内核，输入里写 `device gpu` 启用，`cudaArch` 选计算能力 |
| [jdftx](applications/src/jdftx) | 1.7.0 | `jdftx`、`phonon`、`wannier`，GBRV 和 SG15 赝势；镜像没有 MPI 时编多线程版 | 另装 `jdftx_gpu` 等 GPU 程序，`cudaArch` 选计算能力 |
| [deepmd-kit](applications/src/deepmd-kit) | 3.2.0 | `dp` 和 `deepmd.calculator.DP`，PyTorch 2.13.0 后端，源码编译并链接镜像的 MPI | CUDA 12.6 版 PyTorch 和 DeePMD-kit 自己的 CUDA 内核，`cudaArch` 选计算能力，镜像增加数 GB |
| [dftbplus](applications/src/dftbplus) | 26.1 | `dftb+` 多线程版，含 xTB（tblite）、s-dftd3、输运和 socket | 无 |
| [xtb](applications/src/xtb) | 6.8.0 | `xtb` 和 libxtb；有 Python 时另装 tblite 0.8.0，ASE 计算器为 `tblite.ase.TBLite` | 无 |
| [mopac](applications/src/mopac) | 23.2.5 | `mopac` 和 libmopac | 无 |
| [kim](applications/src/kim) | KIM API 2.4.2 | `kim-api-collections-management` 和示例模型；有 materials-python 时另装 kimpy 2.1.4 | 无 |
| [dftd3](applications/src/dftd3) | 1.7.0 | `dftd3.ase.DFTD3` | 无 |
| [dftd4](applications/src/dftd4) | 4.3.1 | `dftd4.ase.DFTD4` | 无 |
| [atomistica](applications/src/atomistica) | 1.2.7 | Tersoff、EAM 等势函数的 ASE 计算器 | 无 |
| [asap3](applications/src/asap3) | 3.13.11 | EMT 等经典势，链接镜像的 MPI | 无 |

GPAW、ABACUS 和 JDFTx 的交换关联泛函来自 [libxc](infra/src/libxc) Feature（Libxc 6.2.2）。列表中的 LAMMPS、Quantum ESPRESSO、CP2K 和 PLUMED 是已有的 Feature，EMT、TIP3P 和 QM/MM 随 ASE 提供。

几处与上游版本有关的取舍：

- Python 包的版本跟 `wise-platform` 清单，ASE 为 3.26.0。GPAW 26.7.0 和 ABACUS 的 ASE 接口 abacuslite 要求 ASE 3.28 以上，所以 GPAW 装 25.7.0，ABACUS 只装程序本身。
- GPAW 25.7.0 调用的 ELPA C 函数在新版 ELPA 中已改名，GPAW 只用 ScaLAPACK。
- Libxc 7 把泛函编号移出了 `xc.h`，JDFTx 1.7.0 尚未跟进，所以 Libxc 用 6.2.2。JDFTx 自带的 ASE 脚本依赖 ASE 已删除的模块，没有安装。
- DFTB+ 发布包里的 libMBD 只能在其 Git 仓库内配置，多体色散关闭。Slater-Koster 参数文件需另行获取，ASE 通过 `DFTB_PREFIX` 找它们。
- DeePMD-kit 的 PyTorch 2.11 要求 setuptools 低于 82，与清单冲突，所以用 2.13.0 从源码编译。
- CUDA 基座设置 `OMPI_MCA_ess_singleton_isolated=1`：HPC-X 的 Open MPI 不经 `mpirun` 启动时原本会在容器里停住（`import gpaw`、`import asap3`、`dp train`、PLUMED 的 configure 都会遇到）。代价是这样启动的进程不能用 `MPI_Comm_spawn`。`0.1.0-dev.2` 的 CUDA 镜像构建于此之前，仍要用 `mpirun -n 1 …` 启动。[排查记录](../docs/troubleshooting.md)

列表中其余的开源程序还没有 Feature：ABINIT、SIESTA、Octopus、NWChem、Elk、exciting、FLEUR、OpenMX、BigDFT、Psi4、DFTK、Skala、Amber（AmberTools）和 Hotbit。CASTEP、CRYSTAL、DMol³、FHI-aims、Gaussian、ONETEP、Q-Chem、TURBOMOLE 和 VASP 是商业或需单独签约的软件，ORCA、GAMESS-US、GULP、deMon2k、deMon-Nano 和 ACE-Molecule 免费但须各自注册获取、不可再分发，都不在范围内。

## 测试

测试分三级，命令和先后顺序见[发布流程](../docs/release.md)。

| 级别 | 命令 | 检查什么 |
| --- | --- | --- |
| 约定和单元 | `npm test` | [Feature SDK 的约定](../docs/feature-sdk.md#检查规则)、SDK 和 CLI 的单元测试、场景覆盖 |
| 场景 | `npm run test:features -- <变体> <场景\|all>` | 一组 Feature 从基座装起来，检查和算例都通过 |
| 完整镜像 | `npm run test:delivery -- <变体> <镜像>` | 交付镜像的工具、链接、互连、绑核、并行 I/O 和全部算例 |

### 场景测试

场景和断言脚本在 `feature-tests/test/_global/`，遵循 Dev Container Feature Starter 的结构：`scenarios.json`、`scenarios.cuda.json`、`scenarios.smp.json` 和 `scenarios.cloud.json` 各对应一个变体，每个场景列出它安装的 Feature 和选项。`npm run test:features` 把各层的源码整理到临时 `src/`，再逐个调用 `devcontainer features test --global-scenarios-only`；断言通过 Dev Container CLI 的 `check` 和 `reportResults` 执行。[Feature Starter](https://github.com/devcontainers/feature-starter) · [官方测试文档](https://github.com/devcontainers/cli/blob/main/docs/features/test.md)

每个场景使用交付配方锁定的基础镜像。首个场景安装 `core` 和 `openmp`，运行 C、C++ 和 Fortran 双线程归约；选中一个场景时，它所依赖的前置场景先跑。算例以非 root 用户离线运行，校验数值和输出文件。`FEATURE_TEST_BASE_IMAGE` 可指定同一基础镜像的 Harbor 引用，`FEATURE_TEST_APT_SNAPSHOT=''` 可临时使用常规 APT 源，`FEATURE_TEST_GPU=1` 在 GPU 节点带上设备。

CUDA 的 `openmp` 场景另外检查文件句柄、兼容驱动链接，以及 NVCC 和 nvfortran 生成的 `sm_120` 设备代码。LAMMPS 在全量编译前用自己的 NVCC wrapper 重跑链接检查，并把 CUDA 编译控制在 12 路并行。

### 完整镜像验收

`npm run test:delivery` 对一个已构建的镜像运行 `full` 场景（云主机镜像为 `cloud`）：检查工具、链接、互连、绑核和并行 I/O，并重跑各软件的算例。CUDA 默认离线验收，检查 LAMMPS、QE、CP2K 和 ELPA 的 `sm_120` 设备代码；在 GPU 节点设置 `FEATURE_TEST_GPU=1` 后另跑三者的设备算例。检查带着仓库当前的 SDK 读镜像里的登记，较早版本构建的镜像和加过平台入口的镜像都能验。

### 真机自检

镜像部署到运行机器后，用[自检目录](delivery/selftest/)确认每个软件的最小算例都能跑通。自检不装进镜像，也不依赖本仓库的构建系统，CPU 和 CUDA 镜像共用。把 `delivery/selftest/` 整个目录拷到目标机器即可。

```bash
sh run-in-image.sh harbor.will/wise/wise-compute-image:materials-full-cuda-<版本>
sh run-in-image.sh harbor.will/wise/wise-compute-image:materials-full-cpu-<版本> lammps cp2k
```

脚本以 shell 为入口启动容器，把目录只读挂进去执行 `materials-selftest`，逐项输出 `PASS`、`FAIL` 或 `SKIP`、耗时和成功率，有失败时退出码为 1。各项输出和 `result.json` 写到当前目录的 `selftest-logs`。镜像里没有的软件记为 `SKIP`。已在容器内时直接执行 `sh materials-selftest`。

宿主机有 GPU 时自动带 `--gpus all`。CUDA 镜像里的 LAMMPS、Quantum ESPRESSO 和 CP2K 必须在输出中报告自己在 GPU 上计算，否则判失败；以 `variant: cuda` 安装的 GROMACS、GPAW、ABACUS、JDFTx 和 DeePMD-kit 同样要求。看不到 GPU 时设备相关的项记为 `SKIP`，加 `--require-gpu` 则判失败。核对显卡是否符合本交付的编译目标时设置 `SELFTEST_MIN_DRIVER=575 SELFTEST_GPU_CAPABILITY=12.0`。

要连同平台入口一起验（按平台权限启动、经 SSH 运行、经 SCP 和 SFTP 取回），用 [`compute/check.sh`](delivery/compute/README.md#检查)。

## 构建选项和基准

构建时可用 `--base-image` 切到 Harbor 里的兼容上游镜像。CUDA 上游仍需提供 NVIDIA HPC SDK 25.7、CUDA 12.9 和 HPC-X。

```bash
npx wisehub image build --workspace-folder recipe/base/cpu --platform linux/amd64 \
  --base-image harbor.will/docker.io/library/ubuntu:24.04 --image wise-compute:base-cpu
```

[`benchmark.sh`](delivery/benchmark.sh) 在镜像内运行 LAMMPS 或给定的 QE/CP2K 算例，输出耗时、加速比和并行效率 CSV。用 `--hostfile` 测跨节点，用 `--threads` 设置每个 rank 的线程数，用 `--gpu` 测 KOKKOS。
