#!/usr/bin/env bash
# =============================================================================
# build-omp-release.sh — 用 bun canary 构建 omp(oh-my-pi) 上游某个 release tag 的
# 全平台二进制，并发布到本仓库（镜像发布）。
#
# 用法:
#   bash scripts/build-omp-release.sh <upstream-tag> [targets]
#     <upstream-tag>  上游 tag，如 v17.2.9（或任意 git tag/分支）
#     [targets]       逗号分隔的 target id；默认 all（7 个平台）
#                     可选: win32-x64, darwin-arm64, darwin-x64, linux-x64,
#                           linux-musl-x64, linux-arm64, linux-musl-arm64
#
# 依赖: bun(canary) / git / curl / python3(zipfile) / gh(仅发布步骤)
#
# 背景知识(踩坑记录):
#   * bun canary 不做 npm 包发布，bun build --compile 交叉编译时按版本去 npm
#     拉运行时必然 404。绕过: 把运行时二进制预置到
#     $BUN_INSTALL_CACHE_DIR/bun-<compile-target>-v<主.次.修>，bun 检查到文件
#     存在即跳过下载（源码 src/standalone_graph/StandaloneModuleGraph.rs）。
#   * canary tag 是移动 tag，zip 资产用 aarch64 命名（bun-linux-aarch64.zip）。
#   * pi_natives 原生模块（Rust/N-API）不交叉编译，直接取官方 npm leaf 包
#     @oh-my-pi/pi-natives-<platform>，版本号 = tag 去掉 v 前缀。
#     musl 目标复用 linux 同名 .node（官方脚本约定）。
# =============================================================================
set -euo pipefail

UPSTREAM_REPO="can1357/oh-my-pi"
TAG="${1:?用法: $0 <upstream-tag> [targets]}"
TARGETS_ARG="${2:-all}"

BUN_CACHE_DIR="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}"
BUN_VERSION="$(bun --version | cut -d. -f1-3)"
VER="${TAG#v}"   # v17.2.9 -> 17.2.9

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "===== [1/6] 克隆 ${UPSTREAM_REPO} @ ${TAG} ====="
git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/omp"
cd "$WORK/omp"

echo "===== [2/6] bun install (bun ${BUN_VERSION}) ====="
if [ -f bun.lock ]; then
  bun install --frozen-lockfile
else
  bun install
fi

echo "===== [3/6] 拉取各平台 pi_natives 原生模块 (npm leaf) ====="
# target id -> npm leaf 平台名（musl 复用 linux 同名 addon）
NATIVE_LEAVES=(win32-x64 linux-x64 linux-arm64 darwin-arm64 darwin-x64)
mkdir -p packages/natives/native
for leaf in "${NATIVE_LEAVES[@]}"; do
  tarball="https://registry.npmjs.org/@oh-my-pi/pi-natives-${leaf}/-/pi-natives-${leaf}-${VER}.tgz"
  code="$(curl -sIL -o /dev/null -w '%{http_code}' "$tarball")"
  if [ "$code" != "200" ]; then
    echo "  [warn] ${leaf}@${VER} 不存在(HTTP ${code})，改用 latest"
    tarball="$(curl -s "https://registry.npmjs.org/@oh-my-pi/pi-natives-${leaf}/latest" \
      | grep -o '"tarball":"[^"]*"' | head -1 | cut -d'"' -f4)"
  fi
  curl -sL "$tarball" | tar -xz -C "$WORK" package
  cp "$WORK"/package/*.node packages/natives/native/
  echo "  + $(ls "$WORK"/package/*.node | xargs -n1 basename | tr '\n' ' ')"
done
ls -la packages/natives/native/

echo "===== [4/6] 注入 bun canary 各平台编译运行时 (canary tag) ====="
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
mkdir -p "$BUN_CACHE_DIR"
for entry in "${RUNTIMES[@]}"; do
  id="${entry%%|*}"; rest="${entry#*|}"; asset="${rest%%|*}"; cname="${rest#*|}"
  curl -sL -o "$WORK/rt.zip" "https://github.com/oven-sh/bun/releases/download/canary/${asset}"
  python3 -m zipfile -e "$WORK/rt.zip" "$WORK/rt"
  rtbin="$(find "$WORK/rt" -type f \( -name bun -o -name bun.exe \) | head -1)"
  cp "$rtbin" "$BUN_CACHE_DIR/${cname}-v${BUN_VERSION}"
  rm -rf "$WORK/rt" "$WORK/rt.zip"
  echo "  + ${cname}-v${BUN_VERSION}  <-  ${asset}"
done

echo "===== [5/6] 构建二进制 ====="
if [ "$TARGETS_ARG" = "all" ]; then
  TARGETS="win32-x64,darwin-arm64,darwin-x64,linux-x64,linux-musl-x64,linux-arm64,linux-musl-arm64"
else
  TARGETS="$TARGETS_ARG"
fi
bun scripts/ci-release-build-binaries.ts --targets="$TARGETS"

echo "===== [6/6] 发布到本仓库 ====="
BIN_DIR="packages/coding-agent/binaries"
ls -la "$BIN_DIR"
if [ -z "${GH_TOKEN:-}" ] || ! command -v gh >/dev/null 2>&1; then
  echo "[warn] 无 gh 或 GH_TOKEN，跳过发布（本地测试模式）"
  exit 0
fi
RELEASE_TAG="${TAG}"   # 发布 tag 与上游保持一致（如 v17.2.9）
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "release ${RELEASE_TAG} 已存在，跳过"
  exit 0
fi
( cd "$BIN_DIR" && sha256sum ./* > checksums.txt )
gh release create "$RELEASE_TAG" "$BIN_DIR"/* "$BIN_DIR"/checksums.txt \
  --title "omp ${TAG} (bun canary ${BUN_VERSION})" \
  --notes "**上游**: [${UPSTREAM_REPO} ${TAG}](https://github.com/${UPSTREAM_REPO}/releases/tag/${TAG})

使用 bun canary (${BUN_VERSION}) 交叉编译的全平台镜像构建。包含 7 个平台产物与 SHA256 校验和。"
# 若上游是预发布（tag 含 -），标记为 prerelease
if [[ "$TAG" == *-* ]]; then
  gh release edit "$RELEASE_TAG" --prerelease >/dev/null 2>&1 || true
fi
echo "已发布: https://github.com/${GITHUB_REPOSITORY:-<your-repo>}/releases/tag/${RELEASE_TAG}"
