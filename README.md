# WiseHub

WiseHub 把 Dev Container 工作区构建成镜像，并按 digest 推送和拉取。科学计算镜像按五层分级组织，交付 CPU 与 CUDA 两版材料计算镜像。

| 目录 | 内容 |
| --- | --- |
| [`cli/`](cli) | `wisehub`，Registry 系统的一期 SDK：`image build`、`image push`、`image pull`、`feature publish`，见 [命令协议](docs/protocol-v1.md) |
| [`stack/`](stack) | 五层分级：系统基座 → infra → 工具链 → 科学应用 → 最终交付，见其 [README](stack/README.md) |
| [`docs/`](docs) | [命令协议](docs/protocol-v1.md)、[roadmap](docs/roadmap.md) |

## 开发

需要 Node.js 22.18+。构建镜像需要 Docker 与 Buildx。

```bash
npm ci        # 安装依赖并编译 cli
npm test      # cli 测试与 stack 静态测试，无需 Docker
npx wisehub image build --workspace-folder stack/delivery/cpu --local-features stack --platform linux/amd64 --image wise-compute:materials-cpu
```

## CI/CD

[`.gitlab-ci.yml`](.gitlab-ci.yml)，需要支持 privileged Docker-in-Docker 的 linux/amd64 runner。

| 作业 | 触发 | 内容 |
| --- | --- | --- |
| test | MR、main、tag | `npm test`，打包检查 |
| features | 推送 tag | `wisehub feature publish` 按层发布 Feature 到 `harbor.will/willmat/wise` |
| materials（cpu、cuda 两路） | `stack/`、`cli/` 有改动，或 tag | 构建 `stack/delivery/<variant>`（MR、main 用 `--local-features stack`，tag 用已发布的 Feature）；非 root、断网运行 `verify.sh`（runner 无 GPU，CUDA 版不做设备运行） |
| materials（tag） | 推送 tag | 以上之外：tag 已存在则失败；推送到 `harbor.will/willmat/wise-compute-runtime:<tag>-cpu` 和 `<tag>-cuda`；产出 `release.json` 发布记录（含 Feature 锁文件） |

推送需要 CI/CD 变量 `HARBOR_USER`、`HARBOR_PASSWORD`（masked、protected）和 `HARBOR_CA`（文件变量，Will Root CA）。
