#!/usr/bin/env bash
# Wise Compute 最小复现：逐条验证设计规范中的核心契约。
# 依赖：uv、node/npx；STAGE>=2 还需要 docker（含 buildx）。
set -uo pipefail
cd "$(dirname "$0")"
export DEVCONTAINER_CLI=${DEVCONTAINER_CLI:-"npx -y @devcontainers/cli@0.90.0"}
# wisehub 里用 list 调用，这里包一层可执行脚本
mkdir -p .bin; printf '#!/bin/sh\nexec %s "$@"\n' "$DEVCONTAINER_CLI" > .bin/devcontainer; chmod +x .bin/devcontainer
export DEVCONTAINER_CLI="$PWD/.bin/devcontainer"
STAGE=${STAGE:-3}
pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }
key() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['compose_key'])" "$1"; }

echo "### Stage 1: 组合 / 兼容性 / 生成 / 锁定（无需 docker）"
check "C1 dependsOn 闭包: mpi4py+numpy 共享同一个 python" \
  "./wisehub.py compute plan -f compute.yaml | grep -q \"closure=\\['mpi4py', 'numpy', 'openmpi', 'python'\\]\""
expect_conflict() { local out; out=$(./wisehub.py compute plan --with "$1" 2>&1); local rc=$?; echo "$out" | sed -n '2,$p'; [ $rc -eq 2 ] && echo "$out" | grep -q "$2"; }
check "C2 ABI 冲突明确报错(openmpi+mpich)，exit=2" "expect_conflict mpi4py,openmpi,mpich \"'mpi' provided by multiple\""
check "C3 缺少能力明确报错(mpi4py 无 MPI)，不自动补，exit=2" "expect_conflict mpi4py \"'mpi' required by mpi4py\""
check "C4 生成的 devcontainer.json 可被原生 CLI 独立解析，python 只装一次且在 MPI 之后装 mpi4py" \
  "./wisehub.py compute generate -f compute.yaml >/dev/null && \$DEVCONTAINER_CLI features resolve-dependencies --workspace-folder build/research_v1 2>/dev/null | sed -n '/^{/,\$p' | python3 -c \"import json,sys;o=[x['id'].split('/')[-1] for x in json.load(sys.stdin)['installOrder']];print('  order:',o);assert o.count('python')==1 and o.index('openmpi')<o.index('mpi4py') and o.index('python')<o.index('mpi4py')\""
check "C5 基础镜像以 digest 锁定" "grep -q '\"image\": \".*@sha256:' build/research_v1/.devcontainer/devcontainer.json"
K1=$(key build/research_v1/wisehub.lock.json)
./wisehub.py compute generate --with numpy,mpi4py,openmpi --tag alias:x --out build/alias >/dev/null
check "C6 等价配置(yaml vs --with + 默认值) 得到同一组合缓存键" "[ \"$K1\" = \"\$(key build/alias/wisehub.lock.json)\" ]"
./wisehub.py compute generate --with numpy,mpi4py,mpich --tag variant:x --out build/variant >/dev/null
check "C7 换 MPI 实现 → 组合缓存键改变" "[ \"$K1\" != \"\$(key build/variant/wisehub.lock.json)\" ]"
BAK=$(mktemp); cp features/numpy/install.sh "$BAK"
trap 'cp "$BAK" features/numpy/install.sh; rm -f "$BAK"' EXIT
echo '# touch' >> features/numpy/install.sh
./wisehub.py compute generate -f compute.yaml --out build/touched >/dev/null
cp "$BAK" features/numpy/install.sh; rm -f "$BAK"; trap - EXIT
check "C8 Feature 内容变更(同版本号) → 组合缓存键改变" "[ \"$K1\" != \"\$(key build/touched/wisehub.lock.json)\" ]"
[ "$STAGE" -lt 2 ] && { echo "pass=$pass fail=$fail"; exit $fail; }

echo "### Stage 2: 构建 / 验证 / 组合缓存（需要 docker）"
check "B1 首次构建 + 冒烟验证" "./wisehub.py compute build -f compute.yaml 2>&1 | tee build/b1.log | grep -E 'compose-cache|verify'; grep -q 'compose-cache\\] MISS' build/b1.log && ! grep -q FAIL build/b1.log"
check "B2 install.log 中 python 只安装一次" "[ \$(docker run --rm research:v1 grep -c '^python' /opt/wise/install.log) = 1 ]"
check "B3 mpi4py 链接到镜像内 openmpi" "docker run --rm research:v1 /opt/wise/venv/bin/python -c 'from mpi4py import MPI;print(MPI.Get_library_version())' | grep -qi 'open mpi'"
check "B4 相同锁定配置不同 tag → 组合缓存命中，不重新构建" "./wisehub.py compute build --with numpy,mpi4py,openmpi --tag research:v1-alias 2>&1 | grep -q 'compose-cache\\] HIT'"
check "B5 命中缓存的镜像与原镜像 ID 相同" "[ \"\$(docker image inspect -f '{{.Id}}' research:v1)\" = \"\$(docker image inspect -f '{{.Id}}' research:v1-alias)\" ]"
check "B6 生成的配置脱离 wisehub 用原生 CLI 也能构建" "\$DEVCONTAINER_CLI build --workspace-folder build/research_v1 --image-name standalone:v1 >build/b6.log 2>&1"
[ "$STAGE" -lt 3 ] && { echo "pass=$pass fail=$fail"; exit $fail; }

echo "### Stage 3: 构建与执行解耦（执行面只用 docker + 镜像 ID）"
IMG=$(python3 -c "import json;print(json.load(open('build/research_v1/result.json'))['image_id'])")
check "E1 执行面按镜像 ID 运行 MPI 任务，只读 OCI label 获取环境信息" "./run_job.sh $IMG 2 | tee /dev/stderr | grep -q 'OK'"
check "E2 镜像内不含 wisehub / devcontainer CLI" "docker run --rm $IMG sh -c '! command -v devcontainer && ! command -v wisehub'"
echo "pass=$pass fail=$fail"; exit $fail
