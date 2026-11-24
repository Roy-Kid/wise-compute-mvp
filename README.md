# WiseHub

WiseHub 将 Dev Container 工作区构建为镜像，按 digest 推拉 OCI 镜像，并发布 Dev Container Feature。仓库包含 CPU 和 CUDA 两套材料计算镜像配置。

- [CLI 用法](docs/cli.md)
- [镜像配方、运行与验收](recipe/README.md)
- [待办](docs/roadmap.md)

## 本地开发

需要 Node.js 22.18+。构建镜像还需要 Docker 和 Buildx。

```bash
npm ci
npm test
npx wisehub image build --workspace-folder recipe/delivery/cpu --local-features recipe --platform linux/amd64 --image wise-compute:materials-cpu
```

## CI/CD

[GitLab CI](.gitlab-ci.yml) 在 MR 和主分支运行测试及打包检查。镜像相关 MR 会构建并离线验收 CPU/CUDA 镜像，需要支持 privileged Docker-in-Docker 的 linux/amd64 runner。

每次合并到默认分支 `main` 后，CI 自动将 Feature 发布到 `harbor.will/wise/wise-compute-features`，并用该提交的 Feature 源码构建两套镜像。各自通过离线验收后推送到 `harbor.will/wise/wise-compute-runtime:materials-<cpu|cuda>-<完整提交 SHA>`。`release.json` 记录源码提交、镜像摘要和验收状态。重试会拉取并验收同一提交的已有镜像，CUDA 设备验收在 GPU 节点执行。

发布需要有团队 `wise` 项目推拉权限的 `HARBOR_USER` 和 `HARBOR_PASSWORD`（masked、protected），以及包含 Will Root CA 的文件变量 `HARBOR_CA`。Harbor 应对运行镜像的提交标签启用不可变策略。
