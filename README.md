# WiseHub

WiseHub 将 Dev Container 工作区构建为镜像，按 digest 推拉 OCI 镜像，并发布 Dev Container Feature。仓库包含 CPU 和 CUDA 两套材料计算镜像配置。

- [CLI 命令协议](docs/protocol-v1.md)
- [计算栈、运行与验收](stack/README.md)
- [待办](docs/roadmap.md)

## 本地开发

需要 Node.js 22.18+。构建镜像还需要 Docker 和 Buildx。

```bash
npm ci
npm test
npx wisehub image build --workspace-folder stack/delivery/cpu --local-features stack --platform linux/amd64 --image wise-compute:materials-cpu
```

## CI/CD

[GitLab CI](.gitlab-ci.yml) 在 MR、主分支和 tag 上运行测试及打包检查。镜像相关改动触发 CPU/CUDA 构建和离线验收，需要支持 privileged Docker-in-Docker 的 linux/amd64 runner。

推送 Git tag 会发布 Feature、构建并推送 `harbor.will/willmat/wise-compute-runtime:<tag>-cpu` 和对应的 `<tag>-cuda`，并生成包含 Feature 锁定信息的 `release.json`。镜像 tag 已存在时发布失败。

发布需要设置 `HARBOR_USER` 和 `HARBOR_PASSWORD`（masked、protected），以及包含 Will Root CA 的文件变量 `HARBOR_CA`。
