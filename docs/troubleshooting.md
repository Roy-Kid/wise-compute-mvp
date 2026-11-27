# 材料计算镜像排障

在构建机上通过 WiseHub 和 Dev Container CLI 构建、测试材料镜像时实际遇到过的故障，按症状查。每条写了原因和处理办法；流程本身见[发布流程](release.md)。

记录里的"第 N 阶段"和 checkpoint 指早先的分阶段构建：完整镜像分八步编，每步在上一步的镜像上加几个 Feature。那套脚本已随 GitHub、GitLab 流水线删除，现在用 `wisehub image build` 一次构建；阶段号只用来说明问题出在哪个软件上（第 3 步 LAMMPS，第 4 步 Quantum ESPRESSO，第 5 至 7 步 CP2K）。

## CUDA 第 6 阶段的 signal 11 与 CP2K 的编译器

第 6 阶段编译 CP2K 依赖 SIRIUS 7.11.1 时，NVHPC 25.7 的 C++ 前端 `nvcpfe` 以信号 11（`SIGSEGV`）退出。这是编译器前端崩溃，发生在生成目标文件时，与宿主机内存无关。

```text
nvc++-Fatal-/opt/nvidia/hpc_sdk/Linux_x86_64/25.7/compilers/bin/tools/nvcpfe TERMINATED by signal 11
make[2]: *** [src/CMakeFiles/sirius_cxx.dir/build.make:93: src/CMakeFiles/sirius_cxx.dir/hamiltonian/hamiltonian_k.cpp.o] Error 2
```

在第 5 阶段镜像里单独复现后确认了三点。`hamiltonian_k.cpp` 和 `non_local_operator.cpp` 都会崩溃，后者未经任何改写。加 `-nomp` 即可通过，`-O0` 仍然崩溃，所以触发点在 OpenMP。`non_local_operator.cpp` 的触发点是 `apply_U_operator` 里循环上界带强制转换的那条 `#pragma omp parallel for`。上游在 SIRIUS 7.12.0 修复了这类问题，未改动的 7.12.0 源码能用 NVHPC 25.7 编过。[SIRIUS PR 1169](https://github.com/electronic-structure/SIRIUS/pull/1169)

升级 SIRIUS 解决不了 CP2K。继续往下编时，CP2K 的必需依赖 DBCSR 2.10.0 被 nvfortran 拒绝，报 `NVFORTRAN-S-0457-Illegal expression in initialization`，涉及 `dbcsr_types.F` 等几十处派生类型的默认构造初始化。NVHPC 26.11 的 nvfortran 结果相同。nvfortran 25.7 读取 LIBXS 1.0.0 的模块时还会报内部错误 `Invalid sptr in mod file`。换新版 NVHPC 因此不在考虑之内。

另一头，Quantum ESPRESSO 的 NVIDIA GPU 版只能用 NVHPC 编译，它的 `CMakeLists.txt` 在 `QE_GPU` 含 `cuda` 或 `openacc` 时要求编译器为 NVHPC。MPI 的 Fortran 模块又和编译器绑定，HPC-X 只带 nvfortran 的模块，gfortran 编的 CP2K 无法使用。[QE CMakeLists.txt](https://gitlab.com/QEF/q-e/-/blob/9f93ddec427d2b9a45bb72d828c6d324f62fcabd/CMakeLists.txt)

当前做法是在同一个 CUDA 镜像里保留两套工具链。LAMMPS、QE 和 infra 库继续使用 HPC-X 和 NVHPC。CP2K 留在正式版 2026.2，用 GCC、gfortran 和 CUDA 构建，它的工具链在 `/usr/local/cp2k-deps` 自建 Open MPI、OpenBLAS、FFTW、ScaLAPACK、ELPA 和 HDF5。这套依赖不进默认 `PATH` 和动态库缓存。`/usr/local/bin` 下的 `cp2k.psmp` 等命令先设置环境再启动程序，并行运行用 `cp2k-mpirun`。用镜像的 `mpirun` 启动 CP2K 会直接报错退出，避免各进程互不连通地各算各的。[GNU 栈环境](../recipe/applications/src/cp2k-integrals/gnu-stack.sh) · [运行命令](../recipe/applications/src/cp2k/gnu-run.sh)

CUDA 版 CP2K 启动时初始化 CUDA，无 GPU 的构建机上执行 `cp2k.psmp --version` 会以 `cuInit failed with error: 100` 中止。离线验收从 `libcp2k` 读取特性名，CP2K 算例在 GPU 节点设置 `FEATURE_TEST_GPU=1` 后执行。

## DockerBuilder、网络和 APT

### 当前环境没有 Docker CLI 或 Docker daemon

本地工作环境没有可用的 `docker`。实际构建在指定的 DockerBuilder 上执行，使用该主机的 Docker 28.1.1、Buildx 和 Node.js。本地源码传到构建机的工作区后，从那里执行 WiseHub 和 Dev Container CLI。Ubuntu 24.04 是容器基座的用户空间版本，构建机 Pod 曾使用 Ubuntu 20.04。CPU 基座是锁定 digest 的 Ubuntu 24.04，CUDA 基座是锁定 digest 的 NVIDIA HPC SDK 25.7，提供 CUDA 12.9 和 HPC-X。[CPU Dockerfile](../recipe/base/cpu/.devcontainer/Dockerfile) · [CUDA Dockerfile](../recipe/base/cuda/.devcontainer/Dockerfile)

### BuildKit 创建构建挂载时报权限错误

早期构建在 Buildx 准备构建上下文或快照挂载时被宿主环境拒绝，发生在 Feature 安装之前。本轮留存的成功日志显示 Dev Container CLI 调用 `docker buildx build --load`，其中 `--build-context dev_containers_feature_content_source=…` 指向在构建机上整理的 Feature 内容。BuildKit 在自己的执行环境挂载这些内容。运行 Feature 测试时，CLI 另会把构建机上生成的测试工作区 bind mount 到测试容器。

在报错的主机上先检查当前 Docker context、服务端和 builder 驱动，再从同一个工作区跑 OpenMP 场景。若同一主机在执行 Buildx 挂载时持续报 `operation not permitted`，换用具备该权限的 DockerBuilder。早期失败主机的原始挂载目标和完整错误行未保留，适合用构建日志的报错步骤来分辨是 BuildKit 挂载失败还是测试运行时的 bind mount 失败。[Docker BuildKit](https://docs.docker.com/build/buildkit/) · [Dev Container CLI 测试](https://github.com/devcontainers/cli/blob/main/docs/features/test.md)

```bash
docker context show
docker version
docker buildx inspect
npm run test:features -- cpu openmp
```

在 Lavas Pod 中排查自建 `dockerd` 时，用 `docker info` 和 daemon 日志确认权限、存储驱动及数据目录。当前 DockerBuilder 的 `overlay2` 数据目录是 `/opt/lavas/docker`，底层是本地 ext4。工作区仍可保存在 `/mdata`，Docker 数据目录选用支持镜像层存储的本地文件系统。若 Pod 的 PID 1 是 Lavas agent，通过 daemon 进程和日志检查状态。

### Docker Hub 拉取失败，或构建里的 APT 和 Git 连不上

本轮遇到公网镜像直连受限。排查时分别确认拉取基础镜像的 daemon 或 builder、Feature 构建中的 APT 和 Git、以及容器运行时的进程使用了相应代理。给 CLI 所在 shell 设置代理后，构建场景会转发代理 build args。DockerBuilder 已运行的 daemon 则读取其启动环境或 daemon 配置。内网域名后缀 `.will` 和 `.wq` 走直连。[Docker daemon 代理](https://docs.docker.com/engine/daemon/proxy/) · [Docker CLI 容器代理](https://docs.docker.com/engine/cli/proxy/)

```bash
# WISE_PROXY_URL 取当前环境分配的代理地址
export HTTP_PROXY="$WISE_PROXY_URL" HTTPS_PROXY="$WISE_PROXY_URL"
export http_proxy="$WISE_PROXY_URL" https_proxy="$WISE_PROXY_URL"
export NO_PROXY="localhost,127.0.0.1,::1,.will,.wq"
export no_proxy="$NO_PROXY"
docker pull ubuntu:24.04
```

可用 `FEATURE_TEST_BASE_IMAGE` 或 WiseHub 的 `--base-image` 指定经核对的 Harbor 基座。仓库给出的 CPU 示例为 `harbor.will/docker.io/library/ubuntu:24.04`。CUDA 替换基座时仍需包含配方要求的 HPC SDK、CUDA 和 HPC-X。拉取替代基座后记录其 digest。[配方说明](../recipe/README.md#验收与基准)

### APT 快照慢、重复下载或卡在 `Ign:`

带快照的日志反复出现 `Ign: … snapshot.ubuntu.com/ubuntu/20261101T000000Z`，CPU OpenMP 首次尝试在下载阶段等待超过 15 分钟。改用实时 Ubuntu 源后该轮构建推进。另有一次固定快照的 Packmol 场景通过，说明这段时间内快照可达性有波动。正常的多阶段构建也会看到多次 APT 下载，各 Feature 按需安装依赖并清理 APT 索引，独立场景从基础镜像开始。

```bash
FEATURE_TEST_APT_SNAPSHOT='' npm run test:features -- cpu openmp
FEATURE_TEST_APT_SNAPSHOT='' npm run test:features -- cuda openmp
```

上面是已有的测试覆盖参数。本轮 DockerBuilder 上 full 的临时交付配置也将 `build.args.APT_SNAPSHOT` 设为空，绕过快照服务排障。该次镜像使用了构建当时实时源提供的软件包版本。发布记录需要注明这一点，复现固定包版本时使用配方的快照。[Ubuntu 快照服务](https://ubuntu.com/server/docs/how-to/software/snapshot-service/)

### QE 拉取 `external/devxlib` 时 TLS 中断

CUDA 第 4 阶段出现 `gnutls_handshake() failed: The TLS connection was non-properly terminated`，紧接着 Git 报直接获取固定子模块提交失败。先从该构建容器确认代理能访问 GitLab，然后保留配方固定提交重试原阶段。本次原有的 `wise_retry` 重试成功，第 4 阶段产出了镜像。[下载重试实现](../recipe/infra/src/core/feature.sh)

## Feature 解析和离线测试

### `Failed to parse feature 'core_0_file-path'` 或 `cannot open …/feature.sh`

有两条实际失败路径。并行启动时 Dev Container CLI 使用的时间戳临时路径发生竞争，表现为找不到 Feature 元数据。WiseHub 现在为每次构建分配自己的临时目录，测试运行器也按场景隔离。另一次 OpenMP 场景缺少 Core，导致安装脚本加载不到 `/usr/local/lib/devcontainer-features/feature.sh`。显式加入 Core 和 OpenMP 后，CLI 能正确生成并安装依赖。以仓库已有的 `test:features` 入口复跑，避免绕过临时目录和依赖整理。[WiseHub 临时目录](../cli/src/devcontainer.ts) · [测试运行器](../scripts/devcontainer-feature-tests.mjs)

### OpenMP 算例编译成功，执行 `./sum-c` 却报 `Permission denied`

CPU 日志显示二进制已经生成，失败发生在从测试 workspace 执行它时。测试 workspace 挂载在构建机的共享文件系统上，执行受到挂载限制。可用 `findmnt -T "$PWD" -o TARGET,SOURCE,FSTYPE,OPTIONS` 检查实际挂载。现在算例在允许执行的 `/tmp` 临时目录生成并运行二进制，容器以 `nobody` 用户和 `--network=none` 运行。C、C++ 和 Fortran 双线程归约均通过。[算例运行器](../recipe/feature-tests/test/_global/examples/run.sh) · [OpenMP 算例](../recipe/feature-tests/test/_global/examples/openmp.sh)

### 构建并行度只有 1

早期编译直接用 `nproc`，受 `OMP_NUM_THREADS=1` 影响。Feature 现在通过 `wise_build_jobs` 单独计算构建并行度，上限 32，LAMMPS CUDA 有单独的 12 路上限。运行 MPI 和 OpenMP 算例时仍按配方配置线程数。[Feature SDK](feature-sdk.md) · [LAMMPS CUDA 构建](../recipe/applications/src/lammps/lammps-cuda.sh)

### MPI 的 PML 加载失败、内存绑定告警或 HCOLL 初始化失败

早期用完整交付场景测第 3 阶段，出现 `openmpi-defaults registered` 断言失败和 `No components were able to be opened in the pml framework`。这个 checkpoint 上尚未安装第 8 阶段的 `openmpi-defaults`。对 checkpoint 使用阶段内已有 Feature 的场景，清空之前继承的 `OMPI_MCA_pml` 以启用自动选择。完整验收使用第 8 阶段镜像，检查 Open MPI 组件、双 rank 通信、绑核以及 ELPA 需要的 MPI 线程级别。

CUDA checkpoint 的测试还输出了 `failed to bind memory` 和 `Hcol library init failed`。在无 RDMA 设备的构建容器里，本轮 MPI、并行 I/O 和 LAMMPS 数值测试仍通过。需要测 RDMA 时在具有相应设备的节点复核传输方式、绑核和运行参数。[Open MPI 默认值](../recipe/infra/src/openmpi-defaults/install.sh) · [交付场景](../recipe/feature-tests/test/_global/examples/delivery.sh)

### 把部分镜像当 full 验收，或 CUDA 算例找不到设备

基座和 checkpoint 只包含各自阶段已经安装的 Feature。用 `test:features` 从基座验证选定依赖，用 `test:delivery` 验证完成第 8 阶段的完整镜像。仓库目前使用官方 `devcontainer features test` 执行断言和算例。先跑 OpenMP，再跑依赖它的库和应用场景。[配方验收命令](../recipe/README.md#验收与基准) · [Dev Container CLI 测试](https://github.com/devcontainers/cli/blob/main/docs/features/test.md)

在无 GPU 的 DockerBuilder 直接运行 CUDA 版 `ld1.x`，曾卡在 MPI singleton 初始化。改用 `mpirun -n 1` 后很快报出 `error code: 9100`，与 QE 的 CUDA 设备枚举失败路径一致。当前 QE 算例通过 `mpirun -n 1` 启动。CUDA 离线验收检查运行库和原生 `sm_120` 设备代码。LAMMPS、QE 和 CP2K 的 GPU 算例需要到 RTX PRO 5000 节点设置 `FEATURE_TEST_GPU=1` 执行，并先确认 `nvidia-smi` 能识别设备。[QE 的 MPI 启动源码](https://github.com/QEF/q-e/blob/9f93ddec427d2b9a45bb72d828c6d324f62fcabd/Modules/mp_world.f90) · [完整镜像验收](../recipe/delivery/verify-image.ts)

## CUDA 应用构建

### LAMMPS 链接时报 CUDA Driver API 符号未定义

编完对象文件后，链接 `lmp` 时报 `liblammps.so.0: undefined reference to cuStreamGetCtx`，同时缺少 `cuCtxPushCurrent_v2` 和 `cuCtxGetDevice`。无 GPU 的 builder 需要 SDK 内的兼容驱动参与跨共享库链接。当前 Feature 在编译前用实际 NVCC wrapper 验证该链路，链接器通过 `-rpath-link` 搜索 `$CUDA_HOME/compat`。离线测试也临时配置该目录，真卡场景使用运行节点提供的 NVIDIA 驱动。[链接预检](../recipe/applications/src/lammps/lammps-cuda.sh) · [CUDA OpenMP 预检](../recipe/feature-tests/test/_global/examples/cuda-preflight.sh)

### LAMMPS 编译出现 `Too many open files in system`

错误发生在 NVCC/Kokkos 密集编译时，出错行可能指向编译器搜索的任意头文件。Linux 给出的这条错误对应系统打开文件表耗尽（`ENFILE`）。检查 `cat /proc/sys/fs/file-nr` 与 `ulimit -n`，前者反映系统文件表，后者用于辨别另一类进程级句柄限制。采样应安排在编译高峰，结束后文件句柄会被释放。[Linux open(2)](https://man7.org/linux/man-pages/man2/open.2.html)

当前 Feature 在编译前查文件表，在编译中遇到该错误时降低并行度，从同一构建目录复用已完成的目标文件。CUDA OpenMP 场景包含从 12 路降到 6 路的模拟回归。随后实际的 RTX PRO 5000 构建完成了第 3 阶段，LAMMPS 的单 rank 和双 rank Lennard-Jones 数值测试均通过。[续编逻辑](../recipe/applications/src/lammps/lammps-cuda.sh) · [数值算例](../recipe/delivery/selftest/lammps.sh)

### QE 7.6 拒绝旧的 CUDA CMake 开关

第 4 阶段报 `QE_ENABLE_OPENACC CMake options are removed`。现在由 Feature 传入 `QE_GPU=openacc;cuda` 和 `QE_GPU_ARCHS=sm_120`，`cudaCC` 在下载源码前校验。第 4 阶段已成功，`cuobjdump --list-elf /usr/local/bin/pw.x` 确认有原生 `sm_120`。[QE CUDA 配置](../recipe/applications/src/quantum-espresso/qe-cuda.sh) · [参数回归](../recipe/feature-tests/quantum-espresso.test.ts)

CPU QE 构建日志另有 `grep: --include=flags.make: No such file or directory`。这是 HDF5 宏校验把 `--include` 放到了结束选项的 `--` 之后，GNU grep 将它读成文件名。排查时把筛选选项放在 `--` 前，核对启用了 `-D__HDF5` 且没有 `-D__HDF5_SERIAL`。当时 CPU QE 的 H₂ 算例和 CPU full 验收仍然通过。[QE 安装脚本](../recipe/applications/src/quantum-espresso/install.sh)

### CP2K 依赖在 NVHPC 下的编译错误

用 NVHPC 编 CP2K 的依赖时先后遇到过 COSTA 的 `nvc++-Error-Unknown switch: -funroll-loops`、SIRIUS 的 `Unsupported initialization in OMP for loop` 和上文的前端段错误。CP2K 及其依赖现在用 GCC 构建，针对这些错误的适配和预检已从配方中移除。原因见本文开头。

### 旧配置里出现 A100 和 H100，新版要打 RTX PRO 5000

旧 CUDA 配方中，QE 一个 `pw.x` 同时包含 `sm_80` 与 `sm_90`，LAMMPS、ELPA 和 CP2K 的配置主要以 A100 为目标。RTX PRO 5000 Blackwell 的计算能力为 12.0。新配方对 LAMMPS 用 `BLACKWELL120`，对 QE 和 ELPA 用 `120`，对 CP2K 工具链用 `RTXPRO5000`。CP2K 显式传 `CMAKE_CUDA_ARCHITECTURES=120`，对固定版 DBCSR 的模型表做了适配，`libcp2k` 已在离线验收中查到原生 `sm_120`。

当前 checkpoint 的 QE、ELPA 和 LAMMPS 库都已查到原生 `sm_120`，LAMMPS 库还列出 `sm_80`。验收以各组件是否包含目标设备代码为准，实际运算在真卡上复核。[CUDA 交付配置](../recipe/delivery/cuda/.devcontainer/devcontainer.json) · [NVIDIA GPU 计算能力](https://developer.nvidia.com/cuda/gpus)

## ASE 计算器 Feature

### `import gpaw`、`import asap3` 或 `dp train` 在 CUDA 镜像上没有反应

带 MPI 编译的 Python 模块在导入时初始化 MPI，DeePMD-kit 训练时会导入已安装的 mpi4py。CUDA 镜像的 HPC-X Open MPI 4.1 不经启动器初始化时要另起守护进程，在容器里会一直等待，与上文 `ld1.x` 的情况相同。CUDA 基座现在设置 `OMPI_MCA_ess_singleton_isolated=1`，不经 `mpirun` 也能立即启动（在 `0.1.0-dev.2` 镜像上实测：不设时 60 秒超时，设后 0.3 秒返回），代价是这样启动的进程不能再用 `MPI_Comm_spawn`。促成这一改动的是 PLUMED：它的 configure 会直接运行一个 MPI 测试程序，CUDA 场景因此停了近 4 小时。`0.1.0-dev.2` 的 CUDA 镜像构建于此之前，在它上面用 `mpirun -n 1 python3 脚本.py` 或 `mpirun -n 1 dp …` 启动，或自行设置这个变量。[Asap 安装脚本](../recipe/applications/src/asap3/install.sh) · [GPAW 算例](../recipe/delivery/selftest/gpaw.sh)

### JDFTx 编译报 `'XC_LDA_X_RAE' was not declared in this scope`

Libxc 7 的 `xc.h` 不再包含 `xc_funcs.h`，JDFTx 1.7.0 生成的泛函表因此找不到编号。libxc Feature 固定在 6.2.2，GPAW、ABACUS 和 JDFTx 共用。[libxc 安装脚本](../recipe/infra/src/libxc/install.sh)

### GPAW 导入报 `undefined symbol: elpa_generalized_eigenvectors_d`

GPAW 25.7.0 直接调用这个 C 函数，ELPA 2026.02 导出的名字是 `elpa_generalized_eigenvectors_a_h_a_d`。GPAW 不链接 ELPA，并行对角化用 ScaLAPACK。[GPAW 安装脚本](../recipe/applications/src/gpaw/install.sh)

### ABACUS 的 CUDA 版链接时报 `cannot find -lnvToolsExt`

ABACUS 只在自己选择 CUDA 架构时查询工具包版本，传入 `CMAKE_CUDA_ARCHITECTURES` 后版本为空，就会去链接 CUDA 12.9 已移除的 nvToolsExt。Feature 把 `nvcc` 报告的版本作为 `CUDAToolkit_VERSION` 传入，并把 HPC SDK 放 cuBLAS、cuSOLVER 和 cuFFT 的目录加进 `LIBRARY_PATH`。[ABACUS 安装脚本](../recipe/applications/src/abacus/install.sh)

### 新 Feature 里的 `if wise_mpi` 总是走无 MPI 分支

在较早构建的镜像上单独加装 Feature 时，镜像里的 Feature SDK 还没有 `wise_mpi`，shell 把未知命令当作条件不成立。先重装 `core` Feature，或从基座重新构建。SDK 4 起每个安装脚本开头声明 `wise_sdk 4`，在这类镜像上会立即以 `wise_sdk: not found` 或“needs Feature SDK”终止，不再静默走错分支；`0.1.0-dev.2` 及更早的镜像属于这种情况。[Feature SDK](feature-sdk.md)

### Quantum ESPRESSO 的 `ld1.x` 在核数很多的机器上跑不完

SMP 镜像不限制 OpenMP 线程数。在 256 核的构建机上，`ld1.x` 开满线程后几乎全在等待，最小算例超过 300 秒。自检对这一步设 `OMP_NUM_THREADS=1`，核数很多的主机上跑原子程序时同样设置。[QE 算例](../recipe/delivery/selftest/quantum-espresso.sh)

## 平台 SSH 入口和打包

### 改名后的 `compute` 用户能改写 `/usr/local/bin`

Node.js 的发布包记着打包者的属主（UID 1000），以 root 解包时保留了下来，`/usr/local/bin`、`/usr/local/lib` 等目录因此属于 1000。把 Ubuntu 自带的 1000 号用户改名为 `compute` 后，跑任务的用户就能改写系统目录。nodejs Feature 现在用 `--no-same-owner` 解包；入口层另外把镜像里所有属于 1000 的文件改回 root，并检查没有遗漏。[平台 SSH 入口](../recipe/delivery/compute/README.md)

### 公钥登录被拒，日志里是账户被锁

Ubuntu 自带的 `ubuntu` 用户在 `/etc/shadow` 里的口令字段是 `!`，表示锁定。sshd 以 `UsePAM no` 运行时拒绝锁定的账户，哪怕公钥正确。入口层把口令字段设为 `*`：没有可用口令，但账户不算锁定。

### SSH 里找不到程序，容器里却能运行

sshd 不带 PAM 时，会话得不到镜像的 `ENV`，而且只读配置里的第一条 `SetEnv`。入口层在构建时把镜像的全部环境变量写进这一条。`compute/check.sh` 逐个比较容器和 SSH 会话的环境变量，缺一个就失败。

### `docker run <镜像> <命令>` 报 `Missing authorized public key`

加了入口的镜像以 sshd 为入口，不接收命令。调试用 `docker run --entrypoint sh`；自检的 `run-in-image.sh` 已经这样做。

### 构建偶尔在解析 `docker/dockerfile:1` 时失败

Dockerfile 首行的 `# syntax=docker/dockerfile:1` 让每次构建都去 Docker Hub 取前端镜像。构建机到 Docker Hub 的连接不稳，表现为 `TLS handshake timeout` 或 `EOF`，几秒内失败，与被构建的 Feature 无关；重跑即可。入口层的 Dockerfile 不写这一行，用构建器自带的前端。

### Multiwfn 单独安装时报 `curl: not found`

它的安装脚本用 curl 下载，却只装了 `unzip`，也不依赖带 curl 的 `openmp` Feature。和别的 Feature 一起装时 curl 恰好已经在，只有它自己的场景会暴露。现在脚本自己安装 `ca-certificates` 和 `curl`。一个 Feature 用到的系统工具，要么由它依赖的 Feature 提供，要么自己装。

### `test:delivery` 在旧镜像上报 `wise_mpi: not found`

验收脚本调用了镜像里那版 SDK 没有的函数。现在三个验收检查带着仓库的 SDK 进容器，只读镜像里的登记，任何 SDK 版本构建的镜像都能验。[Feature SDK](feature-sdk.md#sdk-版本)

## 核对一次构建

验收脚本里直接执行 `lmp` 会像上文的 `ld1.x` 一样卡在 MPI 单进程初始化，完整镜像验收因此用 `mpirun -n 1` 启动单进程的 LAMMPS 检查。

构建机的本地标签、导出的归档和 Harbor 上的引用是三个位置。确认交付的是哪个镜像时比对镜像 ID：`wisehub image export` 把它写进 `manifest.json`，`wisehub image push` 读回 registry 的 digest 核对。归档先用同目录的 `.sha256` 文件校验，再 `zstd -dc <归档> | docker load` 恢复。[CLI 参考](cli.md)

验收结论取测试报告和命令的退出状态，不凭某条中间告警判定。成功的构建日志里也出现过 locale 配置缺少、`debconf` 无交互前端、容器内 systemd 用户或组缺少，以及 LAMMPS 配置探测 FFmpeg 和 PNetCDF 不可用，这些都不影响结果。

构建机上不要用宽松的 `pkill -f` 模式清理自己的任务：容器里的进程在宿主机上都可见，`chain.sh` 这样的模式会匹配到别的构建里的 `install_cp2k_toolchain.sh`。按完整命令行锚定，或按 PID 结束。
