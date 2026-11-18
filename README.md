# Wise Compute 最小复现用例

这是《Wise Compute：可组合计算镜像设计规范 v1.0.0-draft》的最小可运行验证。
用 5 个极小的 Feature 和一个约 280 行的 `wisehub.py`，逐条检验规范中的核心契约：

`Atomic Features → Composable OCI Images → Reproducible Compute Environments`

## 组成

```text
features/              原子 Feature（标准 devcontainer-feature.json + install.sh）
  python/              系统 CPython + 共享 venv           provides: python-abi=cp312
  numpy/               dependsOn python                    requires: python-abi
  openmpi/  mpich/     两种互斥的 MPI 实现                 provides: mpi=<impl>
  mpi4py/              dependsOn python, installsAfter MPI requires: python-abi, mpi
compute.yaml           Compute Profile（声明式）
wisehub.py             编排器：解析 → 兼容性检查 → 锁定 → 生成 devcontainer.json → 构建 → 验证
run_job.sh             执行面：只用 docker + 镜像 ID/digest 跑 MPI 任务
jobs/hello_mpi.py      计算任务（numpy + mpi4py allreduce）
repro.sh               一键复现，输出 PASS/FAIL
```

兼容性元数据放在 Feature 标准字段 `customizations.wisehub` 中（`provides` / `requires` / `smoke`），
不引入新的文件格式。`devcontainer build` 会把它写进镜像的 `devcontainer.metadata` label。

## 运行

```bash
STAGE=1 ./repro.sh   # 只需 uv + node：组合、兼容性、生成、锁定
./repro.sh           # 完整：再加构建、组合缓存、执行解耦（需要 docker + buildx）
```

也可以直接使用 CLI：

```bash
./wisehub.py compute plan  --with mpi4py,numpy,openmpi
./wisehub.py compute build -f compute.yaml            # → research:v1
./run_job.sh "$(jq -r .image_id build/research_v1/result.json)" 2
```

## 用例与规范条款对照

| # | 用例 | 验证的规范条款 | 预期 |
|---|---|---|---|
| C1 | `mpi4py + numpy + openmpi` 的依赖闭包 | §3.1 原子化、§3.2 共享依赖 | 闭包为 4 个 Feature，python 只出现一次 |
| C2 | `openmpi + mpich + mpi4py` | §3.3 ABI 冲突 | exit 2，报 `'mpi' provided by multiple…`；原生 CLI 本身**不会**拦截 |
| C3 | 只选 `mpi4py` | §3.3 不静默修改用户配置 | exit 2，报缺少 `mpi`，**不**自动补 openmpi |
| C4 | 用原生 `devcontainer features resolve-dependencies` 解析生成的配置 | §4 配置可脱离 wisehub、§3.2 原生 dependsOn/installsAfter | 顺序为 openmpi → python → mpi4py → numpy |
| C5 | 生成的 `image` 字段 | §6.2 锁定 base digest | `ubuntu@sha256:…` |
| C6 | yaml 显式写版本 vs `--with` 使用默认值 | §6.3 组合缓存身份 | 两者 compose_key 相同 |
| C7 | 把 openmpi 换成 mpich | §6.3 | compose_key 改变 |
| C8 | 只改 Feature 脚本、不改版本号 | §6.2 Feature digest | compose_key 改变 |
| B1 | 首次构建并运行每个 Feature 的 smoke 测试 | §5 构建 → 验证 | 缓存 MISS，全部 smoke 通过 |
| B2 | 查看 `/opt/wise/install.log` | §3.2 共享依赖只安装一次 | `python` 只出现 1 行 |
| B3 | mpi4py 链接的 MPI 库 | §3.3 ABI 一致 | 为 Open MPI |
| B4/B5 | 相同锁定配置、不同 tag 再次构建 | §6.1 组合缓存 | 缓存 HIT，不重新构建，镜像 ID 相同 |
| B6 | 不经过 wisehub，直接用原生 `devcontainer build` 构建生成目录 | §4 无专有工具依赖 | 构建成功 |
| E1 | 执行面通过镜像 ID 运行 2-rank allreduce | §7 构建与执行解耦 | 输出 `OK`；环境信息只从 OCI label 读取 |
| E2 | 镜像内没有 devcontainer / wisehub | §7 执行节点无需 Dev Container CLI | 两者都不存在 |

## 复现过程中发现的实现约束（应补进规范）

1. **本地 Feature 的 `dependsOn` / `installsAfter` 路径相对 `.devcontainer/` 解析**，不是相对 Feature 自身目录。
   写成 `../python` 会报 `Resolved path must be a child of the .devcontainer/ folder`，必须写 `./features/python`。
   因此本地 Feature 必须按固定布局复制进生成目录；发布到 OCI Registry 后改用 OCI 引用即可避免这个问题。
2. **Dev Container CLI 只解决安装依赖，不检查运行兼容性**：openmpi 和 mpich 会被同时安装而不报错。
   这证明 §3.3 的补充检查是必要的，而且它是 wisehub 唯一真正“自研”的逻辑。
3. **原生 lockfile 只覆盖 OCI 发布的 Feature**，本地 Feature 不会被锁定。
   所以 `wisehub.lock.json` 补充记录了 Feature 目录内容 digest（C8 验证了这一点），符合 §6.2 中“仅在必要时补充”的要求。
4. **锁定必须真正复用**：如果每次 generate 都重新解析 base tag，既会让结果随 tag 漂移，也会让离线或网络抖动的场景失败。
   本实现在已有 lock 时复用 digest，只有显式传 `--update` 才重新解析。
5. **组合缓存键 ≠ OCI digest**（§6.3）：B4 只是用 compose_key 找到已有镜像；执行面引用的是 `result.json` 里的镜像 ID。
   推送到 registry 后应改为 repo digest。

## 不在本复现范围内

- 软件产物缓存（编译产物复用）、GPU/CUDA 约束、多架构、发布到 Registry、Slurm/K8s 适配。
- 这些都可以在同一骨架上增加一个 Feature 或一条 capability 来扩展，不需要改动整体结构。
