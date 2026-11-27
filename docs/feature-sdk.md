# Feature SDK

`core` Feature（[`recipe/infra/src/core`](../recipe/infra/src/core)）往镜像里装一个 shell 函数库，所有 Feature 的 `install.sh` 都加载它。它让安装脚本查到镜像里实际有什么，并提供下载、校验、链接检查这类公共构建函数。它只在构建镜像时起作用，镜像里的程序运行时不读它。

当前 SDK 版本为 4，`core` 版本 3.2.0。

## 它和 dependsOn 的分工

Dev Container 的 `dependsOn` 在安装开始之前决定装哪些 Feature、按什么顺序。安装脚本进到镜像里执行时看不到这张清单，只能看镜像本身；SDK 是脚本用来看的手段。`dependsOn` 表达不了的四种关系由 SDK 负责：

| 关系 | 例子 | 写法 |
| --- | --- | --- |
| 条件依赖：某个选项打开时才需要 | QE 的 `elpa: true` 需要 elpa Feature | `wise_require_if "$ELPA" elpa` |
| 可选依赖：有就用，没有也行 | OpenKIM 在有 materials-python 时另编 kimpy | `if wise_has materials-python; then …` |
| 能力：几选一 | ABACUS 需要 MPI，Open MPI 或 MPICH 都行 | `wise_require_capability mpi`、`if wise_mpi; then …` |
| 底座自带 | CUDA 底座的 MPI 来自 NVIDIA HPC SDK | 底座设 `WISE_BASE_MPI=openmpi` |

每种关系只声明一次：

- **硬依赖**只写在 `devcontainer-feature.json` 的 `dependsOn`，脚本里不查询。
- **条件依赖、可选依赖、能力**写在脚本的查询调用里，参数是字面量。被查询的 Feature 和能力的提供者必须出现在 `installsAfter`（或 `dependsOn`）里，否则安装顺序不保证；这一点由[检查](#检查规则)保证，不靠人记。

## 安装脚本的形状

```sh
#!/bin/sh
set -eu
wise_id=example
. /usr/local/lib/devcontainer-features/feature.sh
wise_sdk 4

wise_require_capability mpi
wise_require_if "${ELPA:-false}" elpa "elpa=true"
wise_workdir
wise_fetch_git https://example.org/example.git <提交> "$WISE_WORK/src"
# 配置、编译、安装到 $WISE_PREFIX
wise_mpi_linked "$WISE_PREFIX/bin/example"
wise_done
```

`wise_id` 等于 Feature 的目录名。`wise_sdk N` 紧跟在加载之后，`wise_done` 是最后一行。

## SDK 版本

镜像里留的是构建它时的 SDK。`feature.sh` 定义整数 `WISE_SDK`，每增加或改变一个函数加一；每个函数的注释标明它从哪个版本起存在。脚本用 `wise_sdk N` 声明自己需要的最低版本：

- 镜像的 SDK 低于 `N` 时，脚本在这一行报 `needs Feature SDK N and this image has SDK M; install the core Feature again first`。
- 镜像的 SDK 是 3 或更早时没有 `wise_sdk` 这个函数，脚本以 `wise_sdk: not found` 终止。

没有这一行时，新脚本在旧镜像上会把不存在的函数当作不成立的条件，静默走错分支：`0.1.0-dev.1` 的镜像没有 `wise_mpi`，往上追加的 Feature 曾因此悄悄编成无 MPI 版。两种情况的处理办法都是先重装 `core`，它只覆盖函数库。

`core` 自身的版本用 SemVer：增加函数升次版本，删除函数或改变含义升主版本。各 Feature 以 `core:<主版本>` 引用它。

## 登记

`wise_done` 在 `/usr/local/share/devcontainer-features/<id>` 写入：

```text
id=gromacs
version=1.0.0
sdk=4
```

`version` 取自 Feature 自己的 `devcontainer-feature.json`。能力的提供者记在同目录的 `provides/<能力>`。SDK 3 及更早只留空文件，它们仍被视为已安装，版本为空。

镜像里的 `wise-features` 逐行打印 id 和版本，没有版本的打印 `-`。在镜像外用 `wisehub feature list <镜像>` 得到同一张表的 JSON。Feature 的版本不是它所装软件的版本：LAMMPS Feature 是 3.x，装的是 `stable_30Sep2026_update1`。

## 函数

查询和登记，在 `deps.sh`：

| 函数 | 作用 | 起始版本 |
| --- | --- | --- |
| `wise_sdk N` | 声明脚本需要的最低 SDK | 4 |
| `wise_has F` | Feature `F` 是否已安装 | 3 |
| `wise_version F` | 打印 `F` 登记的版本 | 4 |
| `wise_require F [原因]` | 条件比一个布尔选项复杂时，要求 `F` 已安装 | 3 |
| `wise_require_if 值 F [原因]` | 值为 `true` 时要求 `F` 已安装 | 3 |
| `wise_provider C` | 打印能力 `C` 的提供者，来自底座或 Feature | 3 |
| `wise_require_capability C` | 要求有人提供能力 `C` | 3 |
| `wise_mpi` | 镜像是否有 MPI；没有时各 Feature 编多线程版 | 4 |
| `wise_provide C` | 声明自己提供 `C`；已有提供者时失败 | 3 |
| `wise_done` | 登记本 Feature | 3 |

构建，在 `build.sh`（`wise_fail` 在 `feature.sh`），都不在镜像里留状态：

| 函数 | 作用 |
| --- | --- |
| `wise_fail 消息` | 带 Feature 名报错并退出 |
| `wise_retry 命令…` | 最多五次，间隔递增 |
| `wise_download URL SHA256 文件` | 只走 HTTPS，校验不过即失败 |
| `wise_fetch_tar URL SHA256 目录` | 下载、校验并解开一个发布包 |
| `wise_fetch_git URL 提交 目录 [子模块…\|--all]` | 只取一个提交，不带历史 |
| `wise_apt 包…` | 从底座固定的 Ubuntu 快照安装 |
| `wise_workdir` | 设置 `WISE_WORK`，退出时删除 |
| `wise_linked 程序 模式…` | 所有动态库都能解析，且链接了每个模式 |
| `wise_not_linked 程序 模式…` | 没有链接这些库 |
| `wise_mpi_linked 程序 [模式…]` | 链接的正是镜像的那一套 MPI |
| `wise_build_jobs` | 编译并行度，最多 32 |
| `wise_cuda` | 底座是否为 CUDA 底座 |
| `wise_nvfortran_env` | 让 MPI 包装器使用 NVIDIA HPC SDK 的编译器 |

环境变量：`WISE_PREFIX`（`/usr/local`）、`WISE_MPI_ROOT`、`WISE_WORK`。`WISE_REGISTRY` 和 `WISE_SDK_DIR` 可以把登记目录和函数库目录指到别处，供单元测试和验收脚本使用。

## 检查规则

`wisehub feature check recipe` 不构建镜像，读每个 Feature 的元数据和脚本文本来核对；`npm test` 运行同一检查。

| 编号 | 规则 |
| --- | --- |
| C1 | `install.sh` 以 `#!/bin/sh`、`set -eu`、`wise_id=<目录名>`、加载 `feature.sh`、`wise_sdk N` 开头，以 `wise_done` 结尾。`core` 要先安装函数库，只要求后两项 |
| C2 | `N` 不高于仓库的 `WISE_SDK`，不低于脚本所用函数中最晚的起始版本；脚本不调用 SDK 没有定义的 `wise_*` 函数 |
| C3 | `wise_has`、`wise_version`、`wise_require`、`wise_require_if` 的对象在 `installsAfter` 里，且不在 `dependsOn` 里 |
| C4 | 脚本查询某项能力时，仓库里每个提供该能力的 Feature 都在它的 `dependsOn` 或 `installsAfter` 里 |
| C5 | 查询的参数是字面量，且是仓库里存在的 Feature 或有人提供的能力 |
| C6 | 脚本不直接读写登记目录 |
| C7 | `dependsOn` 和 `installsAfter` 的引用都能在仓库里解析，版本标签匹配，没有环 |

检查读的是文本，所以有两条靠评审：不通过探测另一个 Feature 的文件来判断它是否安装；不把查询包在检查程序认不出的写法里（例如把函数名存进变量再调用）。

## 测试

- [`recipe/feature-tests/sdk.test.ts`](../recipe/feature-tests/sdk.test.ts)：在普通 shell 里对临时登记目录运行每个查询和登记函数，不需要 Docker。
- [`cli/test/check.test.ts`](../cli/test/check.test.ts)：仓库本身零违反；逐条规则在仓库副本上改坏一处，确认被报出。
- 场景测试和完整镜像验收里的 `openmp`、`delivery`、`cuda-preflight` 三个检查带着仓库的 SDK 进容器（`examples/sdk`），读镜像里的登记，因此能验任何 SDK 版本构建的镜像。

## 不做的事

- 不做版本求解：一个镜像里每个 Feature 只有一个版本。
- 不做卸载和升级：镜像重建即可。
- 不替代 `dependsOn` 和 `installsAfter`，不引入新的元数据文件。把关系声明在 JSON 的 `customizations` 里再生成清单给脚本读的方案没有采用：安装时镜像里还没有能读 JSON 的工具，生成步骤会让 Feature 只能经 `wisehub` 打包。
