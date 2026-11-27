# WiseHub CLI

```text
wisehub image build    构建 Dev Container 工作区为镜像
wisehub image extend   在已有镜像上再构建一层
wisehub image export   把镜像存成带校验和的归档
wisehub image push     推送并核对 digest
wisehub image pull     按 digest 拉取
wisehub feature check  不构建，检查 Feature 是否符合 SDK 约定
wisehub feature list   列出镜像里装了哪些 Feature
wisehub feature publish 发布 Feature
```

结果以 JSON 写入 stdout，进度和错误写入 stderr，所以输出可以直接交给 `jq`。退出码 `0` 表示成功，`1` 表示执行失败，`2` 表示命令或参数用法错误。在仓库里用 `npx wisehub`；它运行 `npm ci` 时编译出的 `cli/dist`，改过 `cli/src` 后执行 `npm run build`，或直接 `node cli/src/cli.ts`。

## image build

```text
wisehub image build [--workspace-folder DIR] [--config FILE] [--platform OS/ARCH] [--base-image REF]
                    [--local-features RECIPE] (--image NAME | --service-image SERVICE=NAME ...)
                    [-- devcontainer build flags]
```

- `--image` 构建到唯一的临时标签，再按镜像 ID 打目标标签。`--service-image` 声明 Compose 配置中各服务已有的镜像名。指定 `--platform` 时校验实际平台。
- `--base-image REF` 在本次构建中覆盖 Dockerfile 的 `BASE_IMAGE` 参数。配置须使用 `build.dockerfile`，引用可以是完整的 registry 标签或 digest。
- `--local-features RECIPE` 使用配方目录中版本匹配的本地 Feature 副本，构建结束后删除副本；此模式停用锁文件。不带它时由 Dev Container CLI 解析 registry 引用并生成或校验 `devcontainer-lock.json`。
- `--` 后可传入 `--frozen-lockfile` 等构建选项。镜像输出相关的选项由 WiseHub 管理，不能传。

输出 `{ engineVersion, images: [{ reference, id, platform, service? }] }`。

## image extend

```text
wisehub image extend SOURCE --context DIR --image NAME [--platform OS/ARCH] [--build-arg NAME=VALUE ...]
```

用 `DIR` 里的 Dockerfile 在本地镜像 `SOURCE` 之上构建 `NAME`。Dockerfile 以 `ARG BASE_IMAGE` 和 `FROM ${BASE_IMAGE}` 接收 `SOURCE`，因此 `BASE_IMAGE` 不能再作为 `--build-arg` 传入。`SOURCE` 不存在或平台不符时不开始构建。给完整镜像加[平台 SSH 入口](../recipe/delivery/compute/README.md)用的就是它。

输出 `{ reference, id, platform, base: { reference, id, platform } }`。

## image export

```text
wisehub image export IMAGE:TAG ... --output DIR
```

把每个本地镜像存成 `DIR/<TAG>.tar.zst`，旁边写 `sha256sum -c` 可用的 `<TAG>.tar.zst.sha256`，最后写一份 `DIR/manifest.json`。每个镜像都要带标签，标签不能重复，因为它就是归档名。归档先写到 `.partial` 文件，完成后才改成正式名字，中断或失败不会留下残缺的归档。需要 `zstd`，以及大约等于镜像未压缩大小的临时空间。

`zstd -dc <归档> | docker load` 恢复出保存时的引用。

输出 `{ directory, exported, images: [{ reference, id, platform, file, bytes, sha256 }] }`，`manifest.json` 是其中的 `exported` 和 `images`。

## image push 和 image pull

```text
wisehub image push SOURCE REGISTRY/REPOSITORY:TAG
wisehub image pull REGISTRY/REPOSITORY(:TAG|@DIGEST) [--platform OS/ARCH]
```

- `push` 发布单平台镜像并读回 manifest，核对 manifest digest 与源镜像配置 digest。目标 tag 已指向同一镜像时直接返回。输出 `{ tag, digest, reference }`。
- `pull` 先把远端引用解析为 digest 再拉取，避免因 tag 移动而拉到别的镜像。输出 `{ digest, reference, image: { reference, id, platform }, platformManifestDigest? }`。

远端引用须包含显式的 registry 主机（带点、带端口或 `localhost`）。输出中的 `reference` 可直接用于按 digest 拉取。

## feature check

```text
wisehub feature check RECIPE
```

不构建镜像，逐个比对 `RECIPE` 里每个 Feature 的 `install.sh`、`dependsOn` 和 `installsAfter` 是否符合 [Feature SDK 的约定](feature-sdk.md#检查规则)：脚本声明的 SDK 版本够用，脚本查询的 Feature 和能力都排在它之前，硬依赖不重复查询。`npm test` 对仓库的 `recipe` 运行同一检查。

输出 `{ findings: [{ feature, rule, message }] }`；有违反时退出码为 `1`。

## feature list

```text
wisehub feature list IMAGE [--record FILE]
```

读出本地镜像里 `core` 登记的 Feature。不经过镜像自己的入口，也不联网。用 Feature SDK 4 以前构建的镜像没有记录版本，对应的值为 `null`。

`--record FILE` 把这张表写进 JSON 文件 `FILE` 的 `features` 字段，其余字段不动；有任何 Feature 缺版本时拒绝写入。

输出 `{ image: { reference, id, platform }, features: { <id>: <版本或 null> } }`。

## feature publish

```text
wisehub feature publish RECIPE --registry HOST --namespace NAMESPACE
```

发布前校验 `RECIPE/<collection>/src` 中的 Feature 依赖引用和版本，再按依赖顺序发布到 `HOST/NAMESPACE/<collection>`。已存在的版本会跳过，所以改过的 Feature 要先递增 `version`。新版本按 Dev Container CLI 的规则生成版本标签。

输出 `[{ collection, namespace, features }]`。

## 运行环境

镜像操作需要 Docker 和 Buildx。Docker 须支持 `docker image push --platform` 和 `docker image inspect --platform`。Docker 与 Dev Container CLI 都读取 Docker 凭据，私有 CA 需分别配置到 Docker 和 `NODE_EXTRA_CA_CERTS`。镜像推送凭据也须有拉取权限，用于读回校验。

Registry 错误带 `wisehub [类别]` 前缀。类别为 `authentication`、`permission`、`missing`、`conflict`、`temporary`、`integrity` 或 `backend`。

其他 Dev Container 操作直接用 `devcontainer` CLI。
