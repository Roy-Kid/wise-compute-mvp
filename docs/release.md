# 发布流程

从改动一个 Feature 到把镜像交给平台的全部步骤。仓库没有 CI，步骤在有 Docker、Buildx 和 zstd 的构建机上手工执行；`npx wisehub` 用的是 `npm ci` 时编译出的 CLI，改过 `cli/src` 后先 `npm run build`。

| 步骤 | 命令 | 需要 Docker | 耗时 |
| --- | --- | --- | --- |
| 1. 约定检查和单元测试 | `npm test` | 否 | 几秒 |
| 2. 场景测试 | `npm run test:features` | 是 | 每个场景几分钟到几小时 |
| 3. 构建完整镜像 | `wisehub image build` | 是 | CPU 数小时，CUDA 约一天 |
| 4. 完整镜像验收 | `npm run test:delivery` | 是 | 几分钟 |
| 5. 加平台入口 | `wisehub image extend` | 是 | 一两分钟 |
| 6. 平台式检查 | `compute/check.sh` | 是 | 几分钟 |
| 7. 记录和导出 | `wisehub feature list`、`wisehub image export` | 是 | 每个镜像几分钟 |

## 1. 约定检查和单元测试

```bash
npm ci
npm test
```

包含 CLI 的单元测试、[Feature SDK](feature-sdk.md) 的单元测试、`wisehub feature check recipe` 的全部规则，以及"每个 Feature 和交付里用到的选项都有场景覆盖"的检查。改过 Feature 的 `install.sh` 后递增它的 `version`：已发布的版本不会被覆盖，不升版本的改动发布不出去。

## 2. 场景测试

```bash
npm run test:features -- cpu openmp      # 一个场景，连同它依赖的前置场景
npm run test:features -- cpu all
npm run test:features -- cuda all
```

每个场景从基座开始安装一组 Feature，再以非 root 用户离线运行检查和最小算例。场景在 `recipe/feature-tests/test/_global/scenarios*.json`，变体为 `cpu`、`cuda`、`smp` 和 `cloud`。没有 GPU 的机器上 CUDA 场景只验证编译、链接和 CPU 路径；在 GPU 节点加 `FEATURE_TEST_GPU=1`。

## 3. 构建完整镜像

```bash
npx wisehub image build --workspace-folder recipe/delivery/cpu --local-features recipe \
    --platform linux/amd64 --image wise-compute:materials-cpu
```

`--local-features recipe` 用仓库里的 Feature 源码，不写这个选项则从 Harbor 拉取已发布的版本。四套交付的目录是 `recipe/delivery/{cpu,cuda,smp,cloud}`。

## 4. 完整镜像验收

```bash
npm run test:delivery -- cpu wise-compute:materials-cpu
FEATURE_TEST_GPU=1 npm run test:delivery -- cuda wise-compute:materials-cuda   # 在 GPU 节点
```

以非 root 用户离线检查工具、链接、互连、绑核和并行 I/O，并重跑各软件的算例。验收脚本带着仓库当前的 SDK 去读镜像里的登记，所以也能验较早版本构建的镜像；加过平台入口的镜像同样可以验。

## 5. 加平台入口

只有 cpu 和 cuda 两套交付需要。

```bash
npx wisehub image extend wise-compute:materials-cpu --context recipe/delivery/compute --platform linux/amd64 \
    --build-arg COMPUTE_TARGET=aliyun-acs --build-arg VERSION=0.1.0-dev.2 \
    --image harbor.will/wise/wise-compute-image:materials-full-cpu-0.1.0-dev.2
```

CUDA 镜像的 `COMPUTE_TARGET` 是 `aliyun-ack-gpu`。这一层装了什么见[平台 SSH 入口](../recipe/delivery/compute/README.md)。

## 6. 平台式检查

```bash
sh recipe/delivery/compute/check.sh harbor.will/wise/wise-compute-image:materials-full-cpu-0.1.0-dev.2
```

按平台的权限启动镜像（UID 1000、只读根文件系统、无 capabilities、一把只读公钥），经 SSH 运行[自检](../recipe/delivery/selftest)，经 SCP 和 SFTP 取回结果。主机有 GPU 时自动带上，CUDA 版程序必须报告自己在 GPU 上计算。

## 7. 记录和导出

```bash
npx wisehub feature list <镜像> --record recipe/delivery/cpu/lavas-release.json
npx wisehub image export <CPU 镜像> <CUDA 镜像> --output /opt/lavas/wise-compute-images/0.1.0-dev.2
```

`feature list --record` 把镜像里实际装入的 Feature 及其版本写进交付记录的 `features` 字段；记录里的应用版本和 Python 包版本仍然手写。`image export` 为每个镜像写出 `<标签>.tar.zst`、`.sha256` 和一份 `manifest.json`。导出目录另放 `recipe/delivery/selftest` 和 `recipe/delivery/compute`，接收方用它们在目标机器上复查：

```bash
sha256sum -c materials-full-cpu-0.1.0-dev.2.tar.zst.sha256
zstd -dc materials-full-cpu-0.1.0-dev.2.tar.zst | docker load
sh compute/check.sh harbor.will/wise/wise-compute-image:materials-full-cpu-0.1.0-dev.2
```

推到 Harbor 用 `wisehub image push`，Feature 用 `wisehub feature publish`，见 [CLI 参考](cli.md)。

## 版本号

镜像标签为 `<应用>-<变体>-<版本>`，例如 `materials-full-cuda-0.1.0-dev.2`，仓库为 `harbor.will/wise/wise-compute-image`。版本用 SemVer：开发候选版带 `-dev.N` 后缀，正式版为 `MAJOR.MINOR.PATCH`。当前版本记在 [`recipe/delivery/cpu/lavas-release.json`](../recipe/delivery/cpu/lavas-release.json)。

| 版本 | 内容 |
| --- | --- |
| 0.1.0-dev.1 | 首个 CPU 和 CUDA 完整镜像，入口为 shell |
| 0.1.0-dev.2 | 同一套软件加平台 SSH 入口；用 Feature SDK 3 构建，`wise-features` 不可用 |
