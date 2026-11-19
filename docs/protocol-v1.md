# Wise Compute 构建引擎与镜像市场协议 v1

WiseHub 使用 TypeScript 和 Node.js。构建引擎的兼容边界是固定版本的官方 Dev Container CLI。镜像市场通过 OCI Registry 分发镜像，第一阶段只开放推送和拉取。

## 构建引擎

| 操作 | 输入 | 输出 |
| --- | --- | --- |
| `invoke` | 原始命令参数、工作目录、可选取消信号 | 原生标准流和退出状态 |
| `build` | 工作区、可选配置路径、平台、构建参数、镜像输出声明 | 实际平台、镜像 ID、名称、可选 Compose 服务名、引擎版本 |

标准 Dev Container 工作区是第一入口。配置发现、JSONC、Dockerfile、Compose、Features、生命周期、配置合并、变量替换和构建锁由官方 CLI 处理。仓库中的 MPI 示例使用标准 Dev Container 配置。

`wisehub image <native-command> [args...]` 接受所锁定版本的全部公开命令和选项，保留参数顺序、重复选项、`--`、TTY 和退出状态。当前版本的覆盖包括 `read-configuration`、`build`、`up`、`set-up`、`run-user-commands`、`exec`、`outdated`、`upgrade`，以及全部 `features` 和 `templates` 子命令。生命周期按上游命令执行。

`wisehub image build-local` 负责生成本地可推送镜像和结构化结果。单镜像通过 `--image` 声明。Compose 按 `--service-image SERVICE=IMAGE` 声明输出，镜像名称须与 Compose 配置一致。构建完成后检查声明的镜像及平台，记录本地镜像 ID。上游直接推送、导出及其他原生输出模式通过 `invoke` 使用。

## 镜像市场

| 操作 | 输入 | 成功结果 |
| --- | --- | --- |
| `push` | 本地镜像、目标仓库和显式 tag | 目标 tag、Registry 确认的 manifest digest、固定引用 |
| `pull` | 远端 tag 或 digest、可选平台 | 固定引用、实际平台、本地镜像 ID |

Push v1 发布一个平台镜像，校验远端 manifest 的配置 digest 对应源镜像 ID。目标 tag 的覆盖由 Registry 策略决定。确认失败时可用相同输入重试。只有目标当前指向与源镜像匹配的已确认镜像时，重试可以直接成功。调用方保存 `repository@digest` 作为交付凭据。

Pull 首先解析远端 descriptor，然后按固定 digest 拉取。多平台索引保留顶层 digest，Docker 根据平台选择实际镜像，返回镜像 ID 与实际平台。能从索引匹配到对应配置时，同时返回平台 manifest digest。错误至少区分认证、权限、缺失、冲突、临时故障和产物校验失败。凭据和 TLS 信任由工作器的 Docker 配置提供。

## Harbor 部署示例

配置将 OCI 后端绑定到 `harbor.will`。Registry 已存在的项目可用作路径前缀，例如 `harbor.will/wise-compute/research:v1`。后端复用 Docker 已配置的凭据。项目、权限与 CA 由部署方配置。推送凭据须同时具备拉取权限，以便读回确认的 manifest。Docker Engine API 1.49+ 和 Buildx 用于平台检查及远端 descriptor 查询。

```bash
npm ci
npm run build
# 在已有 devcontainer.json 的工作区执行，或用 --workspace-folder 指定工作区。
node dist/cli.js image --help
node dist/cli.js image build-local --workspace-folder . --image research:local
WISE_REGISTRY=harbor.will node dist/cli.js image push research:local harbor.will/wise-compute/research:v1
WISE_REGISTRY=harbor.will node dist/cli.js image pull harbor.will/wise-compute/research@sha256:${IMAGE_DIGEST_HEX}
```

使用合法的 digest 替换示例占位符。上线验收在两个工作器进行。第一个通过标准 Dev Container 配置完成构建和 MPI 冒烟测试，推送到 Harbor，第二个按返回的 digest 拉取并重复冒烟测试。市场侧还验证重复推送、无权限、镜像缺失和 tag 变化。

## 上游参考

- [Dev Container CLI](https://github.com/devcontainers/cli)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)
- [Harbor 推拉文档](https://goharbor.io/docs/main/working-with-projects/working-with-images/pulling-pushing-images/)

## CPU 和 CUDA 交付

两份标准 Dev Container 交付配方位于 `stack/delivery/cpu` 和 `stack/delivery/cuda`。各自产出一个 all-in-one 镜像。层级、Feature 契约和验收条件见 [全量重构规范](refactor-spec.md)。
