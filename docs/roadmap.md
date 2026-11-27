# 待办

## 尚未验证

- **GPU 路径。** 构建机没有 GPU。CUDA 镜像里 LAMMPS、QE、CP2K 的设备算例，以及 GROMACS、GPAW、ABACUS、JDFTx、DeePMD-kit 的 `variant: cuda`，都只验证了编译、链接和 CPU 路径。需要在 RTX PRO 5000 真机上跑 `compute/check.sh` 和 `FEATURE_TEST_GPU=1` 的验收。
- **用 Feature SDK 4 重建完整镜像。** `0.1.0-dev.2` 的软件是 SDK 3 构建的，没有 `wise-features` 和版本登记。重建后把 Feature 表写进交付记录。
- **多节点。** MPI 只在单容器内验证过，跨节点的互连、扩展性和并行效率没有基线。
- **SMP 路径上的 ASE 计算器。** 新增的 13 个 Feature 没有在无 MPI 的镜像上测过。

## 尚未完成

- **自动化。** GitHub 和 GitLab 的流水线已移除，测试、构建和发布按[发布流程](release.md)手工执行。Feature 发布到 Harbor 也是手工的。
- **CUDA 完整镜像的构建时间。** 原来靠分阶段构建和拆分 LAMMPS 编译控制在可接受范围内，这些脚本已删除，现在一次构建约一天，中途失败要从 Docker 缓存续。
- **ASE 列表里还没有 Feature 的开源程序。** ABINIT、SIESTA、Octopus、NWChem、Elk、exciting、FLEUR、OpenMX、BigDFT、Psi4、DFTK、Skala、AmberTools 和 Hotbit。其中带 MPI 的 Fortran 程序在 CUDA 基座上要么用 nvfortran 编，要么像 CP2K 一样自带一套 GNU 工具链，需要先定方案。
- **Python 包版本。** ASE 跟平台清单停在 3.26.0，因此 GPAW 用 25.7.0，ABACUS 没有 ASE 接口。平台升级 ASE 后跟进。
- **registry。** 基座还没有发布到 Harbor 并按 digest 引用；没有发布记录查询和 Feature 弃用功能。
