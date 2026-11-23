# WiseHub CLI

结果以 JSON 写入 stdout，进度和错误写入 stderr。退出码 `0` 表示成功，`1` 表示执行失败，`2` 表示命令或参数用法错误。

## 构建镜像

```text
wisehub image build [--workspace-folder DIR] [--config FILE] [--platform OS/ARCH]
                    [--local-features STACK] (--image NAME | --service-image SERVICE=NAME ...)
                    [-- devcontainer build flags]
```

`--image` 构建到唯一的临时标签，再按镜像 ID 打目标标签。`--service-image` 声明 Compose 配置中各服务已有的镜像名。指定 `--platform` 时会校验实际平台。

默认由 Dev Container CLI 解析 registry 引用并生成或校验 `devcontainer-lock.json`。`--local-features STACK` 使用版本匹配的本地 Feature 副本，构建结束后删除副本，此模式停用锁文件。`--` 后可传入 `--frozen-lockfile` 等构建选项。镜像输出相关选项由 WiseHub 管理。

输出 `{ engineVersion, images: [{ reference, id, platform, service? }] }`。

## 推拉镜像

```text
wisehub image push SOURCE REGISTRY/REPOSITORY:TAG
wisehub image pull REGISTRY/REPOSITORY(:TAG|@DIGEST) [--platform OS/ARCH]
```

- `push` 发布单平台镜像并读回 manifest，核对 manifest digest 与源镜像配置 digest。目标 tag 已指向同一镜像时直接返回。输出 `{ tag, digest, reference }`。
- `pull` 将远端引用解析为 digest 后再拉取，避免因 tag 移动而拉到其他镜像。输出 `{ digest, reference, image: { reference, id, platform }, platformManifestDigest? }`。

远端引用须包含显式 registry 主机（带点、带端口或 `localhost`）。输出中的 `reference` 可直接用于按 digest 拉取。

## 发布 Feature

```text
wisehub feature publish STACK --registry HOST --namespace NAMESPACE
```

发布前校验 `STACK/<collection>/src` 中的 Feature 依赖引用和版本，再按依赖顺序发布到 `HOST/NAMESPACE/<collection>`。已存在的版本会跳过，新版本按 Dev Container CLI 规则生成版本标签。输出 `[{ collection, namespace, features }]`。

## 运行环境

镜像操作需要 Docker 和 Buildx。Docker 须支持 `docker image push --platform` 和 `docker image inspect --platform`。Docker 与 Dev Container CLI 都读取 Docker 凭据，私有 CA 需分别配置到 Docker 和 `NODE_EXTRA_CA_CERTS`。镜像推送凭据也须有拉取权限，用于读回校验。

Registry 错误带 `wisehub [类别]` 前缀。类别为 `authentication`、`permission`、`missing`、`conflict`、`temporary`、`integrity` 或 `backend`。
