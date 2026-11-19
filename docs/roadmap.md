# Roadmap

以下事项尚未实现。实现时把对应条目移入 [architecture](architecture.md) 并补上测试。

## 发布

- **Feature 发布到 OCI。** CI 执行 `devcontainer features publish stack/features/src --registry <host> --namespace <ns>`，然后 `npm run render -w stack -- --feature-registry <host>/<ns>` 生成发布配方。渲染已支持，发布作业和生产 registry 尚未配置；OCI 引用下 `overrideFeatureInstallOrder` 的解析尚未在真实 registry 上验证。
- **配方锁文件。** 发布配方生成并提交 `devcontainer-lock.json`，构建时传 `-- --experimental-frozen-lockfile`。
- **发布记录。** 每个变体一条记录：源码 commit、`stack.json`（含基座 digest 与 apt 快照）、Feature 锁、`devcontainer` 版本、本地镜像 ID、推送后的 `repository@digest`。同一版本号不可覆盖。
- **SBOM。** 从最终镜像导出 `dpkg -l`、`pip freeze`、`conda list` 作为发布产物。

## 验收

- **CUDA 镜像 CI。** 需要带 GPU 的自托管 runner 执行 `verify.sh cuda`。目前只能在 GPU 节点上手动运行。
- **CP2K CUDA 路径。** 当前只有 LAMMPS 有 GPU 构建。
- **应用算例。** MPI 双进程以外，补充 LAMMPS、QE + Wannier90、Packmol 的小算例并核对结果。
- **apt 快照验证。** 快照机制尚未在真实构建中验证；首次 CI 构建需确认 CUDA 基座移除 NVIDIA 源后所有 Feature 正常安装。

## 工具

- **Registry HTTP 客户端。** 当前 descriptor 查询通过 `docker buildx imagetools`，错误靠匹配 stderr 分类。改为直接调用 OCI Distribution API 可按 HTTP 状态码分类，但需要自行处理 Docker 凭据助手和 registry 的 Bearer token 流程，以及 Harbor 自定义 CA。在有真实 registry 的集成测试之前不做。
- **MPICH 配方。** `mpich` Feature 已存在并测试，但还没有选用它的变体；加入时在 `stack.json` 新增变体，并重新验证 mpi4py。
