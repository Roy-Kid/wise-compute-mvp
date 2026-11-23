# Roadmap

- **Registry 与发布**。验证团队 Harbor 账号和 CA，补逐 Feature 测试和版本递增检查。
- **首次全量构建**。在 GitLab runner 验证 CPU/CUDA 构建、镜像大小及 CUDA 依赖的编译和链接，包括 GDRCopy、UCX、ELPA、HDF5、QE 和 CP2K。
- **GPU 与多节点验收**。在 GPU 节点运行 CUDA 验收，补 QE 和 CP2K GPU 算例，采集多节点扩展性基线，按需增加 H100 交付。
- **按需扩展**。新增 LAMMPS 第三方 Feature，将基座发布到 Harbor 并按 digest 引用，增加发布记录查询及 Feature 查询和弃用功能。有真实 registry 集成测试后再评估 OCI HTTP 客户端。
