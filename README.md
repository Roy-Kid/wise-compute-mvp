# WiseHub

WiseHub 使用官方 Dev Container CLI 构建科学计算镜像，并通过 OCI Registry 推送和拉取。设计契约见 [全量重构规范](docs/refactor-spec.md)。

| 层级 | 源码 |
| --- | --- |
| 系统基座 | [stack/base](stack/base)，Ubuntu 24.04 CPU 与同版 Ubuntu 的 NVIDIA CUDA |
| 计算库 | [stack/compute](stack/compute)，OpenMP、Open MPI、MPICH、线性代数、ScaLAPACK |
| 工具链 | [stack/toolchains](stack/toolchains)，Python、Conda、uv、Rust、Node.js |
| 科学应用 | [stack/applications](stack/applications)，NumPy、mpi4py、LAMMPS、CP2K、QE、Wannier90、Packmol |
| 最终交付 | [stack/delivery](stack/delivery)，CPU 和 CUDA 各一份标准 Dev Container 工作区 |

## 安装和构建

需要 Node.js 22+。镜像构建与传输使用 Docker 和 Buildx。

```bash
npm ci
npm run build
npm link

for variant in cpu cuda; do
  wisehub image features resolve-dependencies --workspace-folder "stack/delivery/$variant"
  wisehub image build-local --workspace-folder "stack/delivery/$variant" \
    --platform linux/amd64 --image "wise-compute:$variant"
done
```

Feature 源码使用标准 `src/<id>` 和 `test/<id>`。开发工作区通过标准本地 Feature 引用选择各层。使用 `wisehub image features package stack/toolchains/src --output-folder build/toolchains` 可打包工具链集合。联合验收使用 [交付测试](stack/delivery/test/verify.sh)，CPU 与 CUDA 分别在目标节点执行。CUDA 配方包含独立的 GPU LAMMPS 入口 `lmp-cuda`。

## 运行验收

```bash
docker run --rm --mount "type=bind,src=$PWD/stack/delivery/test,dst=/checks,readonly" \
  --entrypoint /bin/sh wise-compute:cpu /checks/verify.sh cpu
docker run --rm --gpus all --mount "type=bind,src=$PWD/stack/delivery/test,dst=/checks,readonly" \
  --entrypoint /bin/sh wise-compute:cuda /checks/verify.sh cuda
```

推送和拉取使用 [OCI 传输协议](docs/protocol-v1.md)。当前配方用于本地集成，生产 OCI Feature 锁、系统包锁以及 GPU CP2K 资格须在发布前补齐。
