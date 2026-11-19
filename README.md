# WiseHub

WiseHub 用官方 Dev Container 工具链构建 CPU 和 CUDA 两个 all-in-one 科学计算镜像，并按 digest 推送和拉取。

| 目录 | 内容 |
| --- | --- |
| [`cli/`](cli) | `wisehub` 命令行：`image build`、`image push`、`image pull` |
| [`stack/`](stack) | 镜像配方：Feature 集合、[`stack.json`](stack/stack.json)、CPU/CUDA Dockerfile、验收脚本 |
| [`docs/`](docs) | [架构](docs/architecture.md)、[命令协议](docs/protocol-v1.md)、[roadmap](docs/roadmap.md) |

镜像内容：OpenMP、Open MPI、OpenBLAS/LAPACK/FFTW、ScaLAPACK；Python、Conda、uv、Rust、Node.js；NumPy、mpi4py、LAMMPS、CP2K、Quantum ESPRESSO、Wannier90、Packmol。CUDA 版另含 GPU 构建的 `lmp-cuda`。

## 开发

需要 Node.js 22.18+。构建和 Feature 测试需要 Docker 与 Buildx。

```bash
npm ci                              # 安装依赖并编译 cli
npm test                            # 两个 workspace 的静态测试，无需 Docker
npm run test:features -w stack      # 在容器中逐个安装并测试 Feature
```

## 构建与验收

```bash
npm run render -w stack             # 生成 stack/build/recipes/{cpu,cuda}
for variant in cpu cuda; do
  npx wisehub image build --workspace-folder "stack/build/recipes/$variant" \
    --platform linux/amd64 --image "wise-compute:$variant"
done

docker run --rm --mount "type=bind,src=$PWD/stack/recipes,dst=/checks,readonly" \
  --entrypoint /bin/sh wise-compute:cpu /checks/verify.sh cpu
docker run --rm --gpus all --mount "type=bind,src=$PWD/stack/recipes,dst=/checks,readonly" \
  --entrypoint /bin/sh wise-compute:cuda /checks/verify.sh cuda
```

渲染出的工作区是标准 Dev Container 配置，也可以直接交给 `devcontainer build`。

## 常见修改

| 目的 | 修改 |
| --- | --- |
| 增加软件 | 新建 `stack/features/src/<id>` 与 `test/<id>`，在 `stack.json` 的相应层加入 id |
| 升级系统包 | 修改 `stack.json` 的 `aptSnapshot` |
| 升级基座镜像 | 修改 `stack.json` 中对应 `*_IMAGE` 的 digest |
| 升级 pip/直链软件 | 修改对应 Feature 的版本选项或 `install.sh` 中的版本与校验值，并提升 Feature `version` |
