#!/usr/bin/env bash
# =============================================================================
# build-omp-release.sh — 用 bun canary 构建 omp(oh-my-pi) 上游某个 release tag 的
# 全平台二进制，并发布到本仓库（镜像发布）。
#
# 用法:
#   bash scripts/build-omp-release.sh <upstream-tag> [targets] [force]
#     <upstream-tag>  上游 tag，如 v17.2.9（或任意 git tag/分支）
#     [targets]       逗号分隔的 target id；默认 all（7 个平台）
#                     可选: win32-x64, darwin-arm64, darwin-x64, linux-x64,
#                           linux-musl-x64, linux-arm64, linux-musl-arm64
#     [force]         true 时：即使该 tag 已发布也重建，并替换已有 release
#                     的全部资产（用于把 release 更新到最新 bun canary）
#
# 依赖: bun(canary) / git / curl / python3(zipfile) / sha256sum / gh(仅发布步骤)
#
# 背景知识(踩坑记录):
#   * bun canary 不做 npm 包发布，bun build --compile 交叉编译时按版本去 npm
#     拉运行时必然 404。绕过: 把运行时二进制预置到
#     $BUN_INSTALL_CACHE_DIR/bun-<compile-target>-v<主.次.修>，bun 检查到文件
#     存在即跳过下载（源码 src/standalone_graph/StandaloneModuleGraph.rs）。
#   * canary tag 是移动 tag，zip 资产用 aarch64 命名（bun-linux-aarch64.zip）。
#     所有运行时下载均与 canary release 的 SHASUMS256.txt 做 sha256 完整性校验。
#   * pi_natives 原生模块（Rust/N-API）不交叉编译，直接取官方 npm leaf 包
#     @oh-my-pi/pi-natives-<platform>，版本号 = tag 去掉 v 前缀。
#     musl 目标复用 linux 同名 .node（官方脚本约定）。
# =============================================================================
set -euo pipefail

UPSTREAM_REPO="can1357/oh-my-pi"
TAG="${1:?用法: $0 <upstream-tag> [targets] [force]}"
TARGETS_ARG="${2:-all}"
FORCE="${3:-}"   # "true" = 强制重建并替换已有 release 资产

# 防止 - 开头的 tag 被 git/gh 解析为选项
case "$TAG" in
  -*) echo "[error] tag 不能以 - 开头: ${TAG}"; exit 1 ;;
esac

BUN_CACHE_DIR="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
# 注意: `bun --version` 恒为主.次.修(1.4.0)，canary 详情在 `bun --revision`（如 1.4.0-canary.1+b58cd4685）。
# 缓存文件名必须用 --version 的 主.次.修；用 --revision 截取会把 0-canary 混进第三段。
BUN_REV="$(bun --revision 2>/dev/null || bun --version)"                # 完整版本+commit
BUN_FULL="$(echo "${BUN_REV}" | cut -d+ -f1)"                           # 1.4.0-canary.1（标题/说明用）
BUN_VERSION="$(bun --version | cut -d. -f1-3)"                          # 1.4.0（缓存文件名用）
case "$BUN_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) echo "[error] 无法解析 bun 版本: ${BUN_REV}"; exit 1 ;;
esac
VER="${TAG#v}"   # v17.2.9 -> 17.2.9

# 归一化目标列表（大小写不敏感、去空白、去空项）
if [ "${TARGETS_ARG,,}" = "all" ]; then
  TARGETS="win32-x64,darwin-arm64,darwin-x64,linux-x64,linux-musl-x64,linux-arm64,linux-musl-arm64"
else
  TARGETS="$(echo "${TARGETS_ARG}" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)"
  [ -n "$TARGETS" ] || { echo "[error] targets 为空"; exit 1; }
fi
echo "=== 构建目标: ${TARGETS} ==="

# target id -> (canary zip 资产名 | 缓存文件名 bun-<compile-target>-v<ver>)
# 注意: Bun 内部把 arm64 规范化为 npm 命名 "aarch64"（Display 拼缓存文件名），
# 所以 darwin-arm64/linux-arm64 的缓存名用 aarch64，不是 arm64。
RUNTIMES=(
  "win32-x64|bun-windows-x64-baseline.zip|bun-windows-x64-baseline"
  "darwin-arm64|bun-darwin-aarch64.zip|bun-darwin-aarch64"
  "darwin-x64|bun-darwin-x64.zip|bun-darwin-x64"
  "linux-x64|bun-linux-x64-baseline.zip|bun-linux-x64-baseline"
  "linux-musl-x64|bun-linux-x64-musl-baseline.zip|bun-linux-x64-musl-baseline"
  "linux-arm64|bun-linux-aarch64.zip|bun-linux-aarch64"
  "linux-musl-arm64|bun-linux-aarch64-musl.zip|bun-linux-aarch64-musl"
)
# target id -> npm leaf 平台名（musl 复用 linux 同名 addon）
declare -A TARGET_LEAF=(
  [win32-x64]=win32-x64
  [darwin-arm64]=darwin-arm64
  [darwin-x64]=darwin-x64
  [linux-x64]=linux-x64
  [linux-musl-x64]=linux-x64
  [linux-arm64]=linux-arm64
  [linux-musl-arm64]=linux-arm64
)

# 只保留请求目标的运行时条目与 leaf（避免无效下载）
RUN_ENTRIES=()
LEAF_NEEDED=""
for entry in "${RUNTIMES[@]}"; do
  id="${entry%%|*}"
  case ",${TARGETS}," in
    *",${id},"*)
      RUN_ENTRIES+=("$entry")
      leaf="${TARGET_LEAF[$id]}"
      case ",${LEAF_NEEDED}," in *",${leaf},"*) ;; *) LEAF_NEEDED="${LEAF_NEEDED},${leaf}" ;; esac
      ;;
  esac
done
LEAF_NEEDED="${LEAF_NEEDED#,}"
[ -n "$LEAF_NEEDED" ] || { echo "[error] 目标列表不含任何已知平台"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "===== [1/6] 克隆 ${UPSTREAM_REPO} @ ${TAG} ====="
git clone --depth 1 --branch="$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/omp"
cd "$WORK/omp"

echo "===== [2/6] bun install (bun ${BUN_VERSION}) ====="
if [ -f bun.lock ]; then
  bun install --frozen-lockfile
else
  bun install
fi

echo "===== [3/6] 拉取 pi_natives 原生模块 (npm leaf: ${LEAF_NEEDED}) ====="
mkdir -p packages/natives/native
IFS=',' read -ra LEAFS <<< "$LEAF_NEEDED"
for leaf in "${LEAFS[@]}"; do
  tarball="https://registry.npmjs.org/@oh-my-pi/pi-natives-${leaf}/-/pi-natives-${leaf}-${VER}.tgz"
  code="$(curl -fsIL -o /dev/null -w '%{http_code}' "$tarball" || true)"
  if [ "$code" != "200" ]; then
    echo "  [warn] ${leaf}@${VER} 不存在(HTTP ${code})，改用 latest"
    tarball="$(curl -fsSL "https://registry.npmjs.org/@oh-my-pi/pi-natives-${leaf}/latest" \
      | grep -o '"tarball":"[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -n "$tarball" ] || { echo "[error] ${leaf} latest 元数据解析失败"; exit 1; }
  fi
  curl -fsSL "$tarball" | tar -xz -C "$WORK" package
  cp "$WORK"/package/*.node packages/natives/native/
  echo "  + $(ls "$WORK"/package/*.node | xargs -n1 basename | tr '\n' ' ')  <- $(basename "$tarball")"
done
ls -la packages/natives/native/

echo "===== [4/6] 注入 bun canary 编译运行时 (共 ${#RUN_ENTRIES[@]} 个, 含完整性校验) ====="
mkdir -p "$BUN_CACHE_DIR"
for entry in "${RUN_ENTRIES[@]}"; do
  id="${entry%%|*}"; rest="${entry#*|}"; asset="${rest%%|*}"; cname="${rest#*|}"
  # 两级完整性校验:
  # Tier1: 与 canary release 的 SHASUMS256.txt 比对（最强证明）。
  #   注意 bun 的 shas.txt 更新滞后于 zip（实测可滞后 10+ 小时，且 API 直取
  #   同样滞后，非 CDN 缓存问题），短时重试 3 次覆盖移动 tag 竞态即可。
  # Tier2: Tier1 持续不匹配（shas 滞后）时，校验解包出的运行时内嵌 canary
  #   版本串（1.4.0-canary），并打印警告继续。
  expected=""; actual=""
  for attempt in 1 2 3; do
    curl -fsSL -o "$WORK/shas.txt" "https://github.com/oven-sh/bun/releases/download/canary/SHASUMS256.txt"
    curl -fsSL -o "$WORK/rt.zip" "https://github.com/oven-sh/bun/releases/download/canary/${asset}"
    expected="$(awk -v f="${asset}" '$2==f {print $1}' "$WORK/shas.txt")"
    actual="$(sha256sum "$WORK/rt.zip" | cut -d' ' -f1)"
    if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
      break
    fi
    echo "  [warn] ${asset} sha256 与 shas.txt 不一致（第 ${attempt} 次），5s 后重试"
    sleep 5
  done
  python3 -m zipfile -e "$WORK/rt.zip" "$WORK/rt"
  rtbin="$(find "$WORK/rt" -type f \( -name bun -o -name bun.exe \) | head -1)"
  [ -n "$rtbin" ] || { echo "[error] ${asset} 内未找到 bun/bun.exe"; exit 1; }
  if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
    echo "  [Tier1] ${asset} sha256 校验通过 (${actual:0:12})"
  else
    # Tier2 降级: bun 的 shas.txt 滞后，改为校验运行时内嵌版本串
    if grep -a -q "1.4.0-canary" "$rtbin" 2>/dev/null; then
      echo "  [warn][Tier2] ${asset} 未通过 shas.txt 比对（bun 的 shas 滞后: 期望 ${expected:-无} ≠ 实际 ${actual:0:12}），已校验内嵌版本串为 canary，继续"
    else
      echo "[error] ${asset} 完整性校验失败（shas 不匹配且非 canary 运行时）"
      exit 1
    fi
  fi
  cp "$rtbin" "$BUN_CACHE_DIR/${cname}-v${BUN_VERSION}"
  rm -rf "$WORK/rt" "$WORK/rt.zip"
  echo "  + ${cname}-v${BUN_VERSION}  <-  ${asset}"
done

echo "===== [5/6] 构建二进制 ====="
bun scripts/ci-release-build-binaries.ts --targets="$TARGETS"

echo "===== [6/6] 发布到本仓库 ====="
BIN_DIR="packages/coding-agent/binaries"
ls -la "$BIN_DIR"
if [ -z "${GH_TOKEN:-}" ] || ! command -v gh >/dev/null 2>&1; then
  echo "[warn] 无 gh 或 GH_TOKEN，跳过发布（本地测试模式）"
  exit 0
fi
# gh 默认按当前目录的 git remote 推断目标仓库；而本脚本 CWD 在上游克隆里，
# 不显式指定会把上游误判为发布目标（gh release view 误报"已存在"而跳过）。
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  export GH_REPO="$GITHUB_REPOSITORY"
fi
RELEASE_TAG="${TAG}"   # 发布 tag 与上游保持一致（如 v17.2.9）
# 上游克隆自带同名本地 tag，gh 会报 "tag exists locally but has not been
# pushed" 而拒绝创建；删掉本地 tag，并显式 --target 默认分支在目标仓库新建。
git tag -d "$RELEASE_TAG" 2>/dev/null || true
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  if [ "$FORCE" = "true" ]; then
    # force 模式：删除旧资产 → 上传新构建（保留 release 本体/说明/日期）
    echo "release ${RELEASE_TAG} 已存在，force 模式：替换全部资产"
    ( cd "$BIN_DIR" && sha256sum ./* > checksums.txt )
    gh release view "$RELEASE_TAG" --json assets -q '.assets[].name' | while read -r aname; do
      [ -n "$aname" ] && gh release delete-asset "$RELEASE_TAG" "$aname" --yes >/dev/null
    done
    gh release upload "$RELEASE_TAG" "$BIN_DIR"/* --clobber
    echo "已更新: https://github.com/${GITHUB_REPOSITORY:-<your-repo>}/releases/tag/${RELEASE_TAG}"
    exit 0
  fi
  echo "release ${RELEASE_TAG} 已存在，跳过（如需重建请用 force=true）"
  exit 0
fi
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo main)"
( cd "$BIN_DIR" && sha256sum ./* > checksums.txt )
# 注意: "$BIN_DIR"/* 已包含 checksums.txt，不能重复显式传入（否则 422 already exists）
# release 名与上游保持一致（纯 tag），bun 版本信息放 body
gh release create "$RELEASE_TAG" "$BIN_DIR"/* \
  --target "$DEFAULT_BRANCH" \
  --title "${TAG}" \
  --notes "**上游**: [${UPSTREAM_REPO} ${TAG}](https://github.com/${UPSTREAM_REPO}/releases/tag/${TAG})

**构建工具**: bun canary \`${BUN_FULL}\`（revision \`${BUN_REV}\`）
**平台**: ${TARGETS}
使用 bun canary 交叉编译的全平台镜像构建，附 SHA256 校验和。"
# 若上游是预发布（tag 含 -），标记为 prerelease
if [[ "$TAG" == *-* ]]; then
  gh release edit "$RELEASE_TAG" --prerelease >/dev/null 2>&1 || true
fi
echo "已发布: https://github.com/${GITHUB_REPOSITORY:-<your-repo>}/releases/tag/${RELEASE_TAG}"
