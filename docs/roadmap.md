# Roadmap

以下事项尚未实现。实现时更新对应 README 并补上测试。

- **Registry 一期落地细节。** 架构已就位（注册表引用、`feature publish`、`--local-features`、CI 发布阶段），尚未对 harbor.will 实际运行。待定：Harbor 项目与命名空间（当前占位 `willmat/wise`）、机器人账号、Will Root CA 的分发（Node 用 `NODE_EXTRA_CA_CERTS`，DinD 守护进程需 `/etc/docker/certs.d/harbor.will/ca.crt`）；首次发布后确认官方 CLI 对带 tag 的 OCI `installsAfter` 的匹配行为；锁文件是入库还是仅作发布记录；MR 中检查改动的 Feature 已提升版本。
- **Registry 后续阶段。** 基座镜像发布到 Harbor 并由交付按 digest 引用；发布记录与版本查询的服务端；SDK 增加 `feature` 的查询与弃用。
- **首次 CI 运行确认。** `.gitlab-ci.yml` 尚未在 git.will.wq 上跑过。需确认：runner 支持 privileged DinD；能拉取 nvcr.io 的 HPC SDK 基座（约 9 GB）并访问 `harbor.will`；Ubuntu 快照源可用；各 Feature 源码构建成功（CUDA 版 LAMMPS KOKKOS、QE OpenACC、CP2K 在 5h 超时内）；镜像大小可接受。
- **GPU 验收。** CI runner 没有 GPU，CUDA 版的设备运行只能在 GPU 节点上执行 `verify.sh cuda`；有 GPU runner 后加进流水线，并补 QE 与 CP2K 的 GPU 算例。
- **逐 Feature 测试。** 各层尚无 `test/<id>`。Feature 间 `dependsOn` 是注册表引用，官方 `features test` 需要下层已发布；在 Registry 一期跑通后补上。
- **Registry HTTP 客户端。** descriptor 查询目前通过 `docker buildx imagetools`，错误靠匹配 stderr 分类。改用 OCI Distribution API 可按 HTTP 状态码分类，但要自行处理 Docker 凭据助手、Bearer token 和 Harbor 自定义 CA；在有真实 registry 的集成测试之前不做。
