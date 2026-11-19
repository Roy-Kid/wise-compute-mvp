# WiseHub 命令协议 v1

`wisehub` 只提供三个命令。其他 Dev Container 操作（`up`、`exec`、`features`、`templates` 等）直接使用官方 `devcontainer` CLI。所有结果以 JSON 写到 stdout，构建和传输进度写到 stderr。

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 执行失败；registry 失败带分类前缀，如 `wisehub [permission]: …` |
| 2 | 用法错误（未知命令、参数缺失或非法） |

## `wisehub image build`

```text
wisehub image build [--workspace-folder DIR] [--config FILE] [--platform OS/ARCH]
                    (--image NAME | --service-image SERVICE=NAME ...) [-- devcontainer build flags]
```

调用随包锁定的 `@devcontainers/cli` 构建工作区，并检查 Docker 实际持有的镜像：

- 单镜像先以唯一临时名 `wise-build/staging:<uuid>` 构建，按镜像 ID 打上 `--image`，再删除临时名，因此并发构建不会互相串号。
- Compose 按 `--service-image` 声明输出，名称须与 Compose 配置一致。
- 指定 `--platform` 时校验实际平台。
- `--` 之后的参数原样传给 `devcontainer build`，例如 `--experimental-frozen-lockfile`。决定输出的参数（`--image-name`、`--push`、`--output` 等）被拒绝；需要这些模式时直接用 `devcontainer`。

输出：`{ engineVersion, images: [{ reference, id, platform, service? }] }`。

## `wisehub image push SOURCE REGISTRY/REPOSITORY:TAG`

发布一个平台的本地镜像并确认 registry 存的正是它：

1. 目标必须带显式 registry 主机（含 `.` 或端口，或 `localhost`）和 tag，防止静默落到 Docker Hub。
2. 若目标 tag 已指向配置 digest 等于源镜像 ID 的 manifest，直接返回，不重复推送。
3. 否则推送，然后读回 `repository@digest`，要求 manifest digest 与 Docker 报告一致、配置 digest 与源镜像 ID 一致。

输出：`{ tag, digest, reference }`。调用方保存 `reference`（`repository@digest`）作为交付凭据。tag 能否被覆盖由 registry 策略决定。

## `wisehub image pull REFERENCE [--platform OS/ARCH]`

先解析远端 descriptor，再按 digest 拉取，tag 在两步之间移动不会影响结果。给定 digest 时要求 registry 返回同一 digest。多平台索引保留顶层 digest，并在能匹配时返回对应平台 manifest digest。

输出：`{ digest, reference, image: { reference, id, platform }, platformManifestDigest? }`。

## 错误分类

Docker 只以文本报告 registry 错误，`docker.ts` 按顺序匹配：`conflict`、`authentication`、`permission`、`missing`、`temporary`，其余为 `backend`；读回不一致为 `integrity`。Docker 对未登录和无权限都输出 `denied: requested access to the resource is denied`，此时报告为 `permission`。

## 凭据与依赖

凭据和 TLS 信任来自运行环境的 Docker 配置（`docker login`、`/etc/docker/certs.d`）。推送凭据须同时具备拉取权限以读回 manifest。需要 Docker Engine API 1.49+ 和 Buildx。

## Harbor 示例

```bash
npm ci
npm run render -w stack -- cpu
npx wisehub image build --workspace-folder stack/build/recipes/cpu --platform linux/amd64 --image wise-compute:cpu
npx wisehub image push wise-compute:cpu harbor.will/wise-compute/cpu:v1
npx wisehub image pull harbor.will/wise-compute/cpu@sha256:<digest> --platform linux/amd64
```

## 上游参考

- [Dev Container CLI](https://github.com/devcontainers/cli)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)
- [Harbor 推拉文档](https://goharbor.io/docs/main/working-with-projects/working-with-images/pulling-pushing-images/)
