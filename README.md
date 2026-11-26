# WiseHub

WiseHub 将 Dev Container 工作区构建为镜像，按 digest 推拉 OCI 镜像，并发布 Dev Container Feature。仓库包含 CPU 和 CUDA 两套材料计算镜像配置。

- [CLI 用法](docs/cli.md)
- [镜像配方、运行与验收](recipe/README.md)
- [轻量 CPU 云主机镜像](recipe/delivery/cloud/README.md)
- [镜像构建和验收排障](docs/troubleshooting.md)
- [待办](docs/roadmap.md)

## 本地开发

需要 Node.js 22.18+。构建镜像还需要 Docker 和 Buildx。

```bash
npm ci
npm test
npm run test:features -- cpu openmp
npx wisehub image build --workspace-folder recipe/delivery/cpu --local-features recipe --platform linux/amd64 --image wise-compute:materials-cpu
npm run test:delivery -- cpu wise-compute:materials-cpu
```

## CI/CD

在 GitHub Actions 手动运行 [Publish materials full CPU and CUDA](.github/workflows/materials-full.yml)，CPU 和 CUDA 的 `linux/amd64` 完整镜像会并行构建。每个镜像在独立任务中依次完成各个[构建阶段](recipe/delivery/stages.ts)。阶段之间通过当前工作流运行中的 checkpoint 传递压缩镜像，CUDA 的八个 LAMMPS 并行任务只传递编译出的目标文件。Checkpoint 保留三天，可供同一次运行重试。离线验收通过的完整镜像推送到 Docker Hub，标签为 `materials-full-<cpu|cuda>-<version>`，版本取自 [发布配方](recipe/delivery/cpu/lavas-release.json)。运行摘要记录各镜像的 digest。CUDA 真机验收需在 GPU 节点执行。

在 GitHub Actions 仓库变量中设置 `DOCKERHUB_REPOSITORY`（`namespace/repository`）和 `DOCKERHUB_USERNAME`，将可读写目标仓库的 PAT 保存为 Actions secret `DOCKERHUB_TOKEN`。任务默认使用 `ubuntu-24.04`。可分别用 `CPU_BUILD_RUNNER` 和 `CUDA_BUILD_RUNNER` 指定已配置的 x64 Linux runner 标签。

[GitLab CI](.gitlab-ci.yml) 在 MR 和主分支运行测试及打包检查。镜像相关 MR 会构建并离线验收材料 CPU/CUDA 镜像与轻量云主机镜像，需要支持 privileged Docker-in-Docker 的 linux/amd64 runner。

每次合并到默认分支 `main` 后，CI 自动将 Feature 发布到 `harbor.will/wise/wise-compute-features`，并用该提交的 Feature 源码构建两套镜像。各自通过离线验收后推送到 `harbor.will/wise/wise-compute-runtime:materials-<cpu|cuda>-<完整提交 SHA>`。`release.json` 记录源码提交、镜像摘要和验收状态。重试会拉取并验收同一提交的已有镜像，CUDA 设备验收在 GPU 节点执行。

发布需要有团队 `wise` 项目推拉权限的 `HARBOR_USER` 和 `HARBOR_PASSWORD`（masked、protected），以及包含 Will Root CA 的文件变量 `HARBOR_CA`。Harbor 应对运行镜像的提交标签启用不可变策略。
