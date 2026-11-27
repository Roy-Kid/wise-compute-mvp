# 平台 SSH 入口

CPU 和 CUDA 材料镜像在完成验收的软件之上加同一层 [Dockerfile](Dockerfile)，由平台以受管 SSH 方式启动。SMP 和云主机镜像不加。

```bash
npx wisehub image extend <验收过的材料镜像> --context recipe/delivery/compute --platform linux/amd64 \
    --build-arg COMPUTE_TARGET=aliyun-acs --build-arg VERSION=<版本> \
    --image harbor.will/wise/wise-compute-image:materials-full-cpu-<版本>
```

CUDA 镜像的 `COMPUTE_TARGET` 是 `aliyun-ack-gpu`。

| 项目 | 内容 |
| --- | --- |
| 入口 | `/usr/local/bin/wise-compute-entrypoint`，即平台的 `images/compute/volc/entrypoint.sh`，未改动 |
| sshd 配置 | `/etc/ssh/wise_compute_sshd_config`，即平台的 `images/compute/aliyun-basic/sshd_config`，只替换那一条 `SetEnv` |
| 平台来源 | `wise-science/wise-platform-aliyun` 提交 `1ddf1e88c0838f67b62ef1491189c96ca43ac7d4` |
| OpenSSH | `openssh-server`、`openssh-client` `1:9.6p1-3ubuntu13.20`，取自两个底座共用的 Ubuntu 24.04 快照 `20261101T000000Z` |
| 用户 | Ubuntu 自带的 `ubuntu`（1000:1000）改名为 `compute:compute`，HOME 为 `/work`，无附加组，无密码 |
| 目录 | `/run/sshd`、`/run/wise-compute`、`/run/wise-compute-host`、`/work`；后两个归 1000:1000 |
| 镜像配置 | `HOME=/work`、`TMPDIR=/work/.tmp`、`USER 1000:1000`、`WORKDIR /work`、`EXPOSE 2222`、入口如上 |

更新平台文件时，从平台仓库原样复制 `entrypoint.sh` 和 `sshd_config`，并改上表的提交号。

## 会话环境

sshd 以 `UsePAM no` 运行，SSH 会话得不到镜像的 `ENV`，而且 sshd 只读第一条 `SetEnv`。[session-env.py](session-env.py) 在构建时把镜像的全部环境变量写进这一条 `SetEnv`：平台原有的默认值保留，镜像里有的变量以镜像为准，`HOME` 和 `TMPDIR` 固定为 `/work` 和 `/work/.tmp`。这样 CPU 和 CUDA 共用一个配方，SSH 里的命令和容器里的命令看到同一份环境，包括 `/opt/venv/bin`、NVHPC 和 CUDA 的路径、`LAMMPS_POTENTIALS` 和线程默认值。代理变量和给 NVIDIA 容器运行时的 `NVIDIA_*` 不写入。

镜像的 `LD_LIBRARY_PATH` 本来就只有 NVHPC 的库；CUDA 版 CP2K 的另一套 MPI 仍只在 `cp2k-mpirun` 等包装脚本内生效，会话环境不含它的路径。

## 入口替换了什么

CPU 镜像原来的命令是 `bash`。CUDA 镜像原来的入口 `/usr/local/bin/entrypoint.sh` 来自 NVIDIA HPC SDK，只打印版本横幅和“未检测到驱动”的提示，然后执行命令；CUDA 环境全部来自镜像的 `ENV`，所以直接换成平台入口，没有需要保留的初始化。入口不接收命令，`docker run 镜像 命令` 不再可用；调试时用 `--entrypoint sh`。

构建时删除安装包生成的 `/etc/ssh/ssh_host_*`，实例的主机密钥由入口在 `/run/wise-compute-host` 生成。软件文件一律归 root：旧镜像里 Node.js 压缩包把 `/usr/local/bin` 等目录留给了 UID 1000，这一层把它们改回 root 并检查没有遗漏。

## 检查

```bash
sh recipe/delivery/compute/check.sh harbor.will/wise/wise-compute-image:materials-full-cpu-<版本>
```

[check.sh](check.sh) 按平台的权限启动镜像：UID/GID 1000、只读根文件系统、去掉全部 capabilities、只读挂载一把申请公钥、可写的 `/work` 和 `/run/wise-compute-host`。它读取入口输出的 `WISE_COMPUTE_HOST_KEY=…` 并只信任这把主机密钥，然后检查：全部进程以 UID 1000 运行；非交互 SSH 会话具有容器的全部环境变量；root、其他密钥和密码登录被拒绝；经 SCP 上传 [selftest](../selftest)、经 SSH 运行、经 SCP 和 SFTP 取回结果。主机有 `nvidia-smi` 时带上全部 GPU。

`selftest/run-in-image.sh` 和 `npm run test:delivery` 不经过入口，以 shell 作为入口直接运行。
