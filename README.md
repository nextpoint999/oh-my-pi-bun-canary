# omp 镜像发布 Workflow

定时检测 [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi) 的新 release，
一旦上游发布新版本，就用**该 tag 的源码 + 最新 bun canary** 交叉编译全部 7 个平台
的二进制，并发布到**你自己的 GitHub 仓库**。

## 工作原理

```
定时(每2h) ──▶ 取上游【最新一个】release ──▶ 已镜像则跳过；未镜像则构建发布
                │
                └─ 已镜像但 bun canary 已前进 ──▶ 自动 force 重建最新版
              ├─ bun install
              ├─ 原生模块: 官方 npm leaf (免 bazel)
              ├─ 运行时: bun canary tag 注入缓存
              └─ bun build --compile 全平台
                   └─ gh release create 发布
```

发布 tag 与上游保持一致（如 `v17.2.9`），附 SHA256 校验和。

## 部署步骤

1. 把本目录两个文件放入你的 GitHub 仓库：

   ```
   .github/workflows/omp-mirror.yml   ← 定时 + 检测 + 发布逻辑
   scripts/build-omp-release.sh      ← 单版本构建脚本
   ```

2. 推送后 workflow 会自动按 cron（UTC 每 2 小时）运行；也可以到
   Actions → **Mirror omp releases** → Run workflow 手动触发：
   - `tag`：指定上游 tag 强制构建（如 `v17.2.9`，含历史版本），留空则自动检测
   - `targets`：构建目标，逗号分隔，默认 `all`（7 平台）
   - `latest`：latest 徽标处理——`auto`（默认，按上游最新版本）/ `set`（本次
     构建版本设为 latest，如强制历史版本上位）/ `keep`（不修改）。
     注意：不能用 yes/no（YAML 会把它们解析为布尔值，GitHub 会拒绝该值）
   - `force`：勾选后**强制重建**——即使该 tag 已发布也重新构建，并替换已有
     release 的全部资产（用于把 release 更新到最新 bun canary；release 本体/
     说明/日期保留，只换二进制和 checksums）

3. 发布权限：workflow 已声明 `permissions: contents: write`，GitHub 自动提供
   GITHUB_TOKEN，无需额外配置。仓库公开后 release 对所有人可见。

## 平台矩阵（target id → 产物）

| target | 产物 | 运行时注入（canary zip） |
|---|---|---|
| win32-x64 | omp-windows-x64.exe | bun-windows-x64-baseline.zip |
| linux-x64 | omp-linux-x64 | bun-linux-x64-baseline.zip |
| linux-musl-x64 | omp-linux-musl-x64 | bun-linux-x64-musl-baseline.zip |
| linux-arm64 | omp-linux-arm64 | bun-linux-aarch64.zip |
| linux-musl-arm64 | omp-linux-musl-arm64 | bun-linux-aarch64-musl.zip |
| darwin-x64 | omp-darwin-x64 | bun-darwin-x64.zip |
| darwin-arm64 | omp-darwin-arm64 | bun-darwin-aarch64.zip |

## 关键实现细节（踩坑记录）

- **canary 无 npm 包**：bun 交叉编译时按 `bun-<os>-<arch>-<版本>.tgz` 从 npm 拉
  运行时，canary 不发布 npm 包必然 404。绕过：把 canary tag 的 zip 里的运行时
  二进制预置到 `$BUN_INSTALL_CACHE_DIR/bun-<compile-target>-v<主.次.修>`，
  bun 检测到文件存在即跳过下载（Bun 源码 `StandaloneModuleGraph.rs`）。
- **arm64 用 aarch64 命名**：bun 内部把 arm64 规范化为 npm 命名 `aarch64`，
  缓存文件名（和 npm URL）都用 aarch64；canary 的 zip 资产也是
  `bun-linux-aarch64.zip` / `bun-darwin-aarch64.zip`。
- **原生模块不交叉编译**：pi_natives（Rust/N-API）直接取官方 npm leaf
  `@oh-my-pi/pi-natives-<platform>@<版本>`，版本号 = 上游 tag 去掉 `v` 前缀；
  缺失时自动回退 latest。musl 目标复用 linux 同名 addon（官方脚本约定）。
- 每轮最多处理 3 个新版本，防止长时间运行超时；遗漏版本由后续轮询自动补齐
  （版本对比基于"本仓库是否已有同名 <tag> release"，幂等可重入）。
- **gh 仓库推断坑**：`gh` 默认按当前目录 git remote 推断目标仓库，而构建脚本 CWD
  在上游克隆里，必须显式 `export GH_REPO="$GITHUB_REPOSITORY"`，否则会把上游
  误判为发布目标（`gh release view` 误报"已存在"导致发布被跳过）。
- **gh 本地 tag 坑**：上游克隆自带同名本地 tag，`gh release create` 会报
  "tag exists locally but has not been pushed"；先 `git tag -d` 再带
  `--target main` 创建。
- **资产重复上传坑**：`"$BIN_DIR"/*` 通配已包含 checksums.txt，不要再显式传入，
  否则 422 `ReleaseAsset.name already exists`（gh 会自动回滚已建 release）。
- **latest 徽标维护**：GitHub 默认按发布时间（而非版本号）决定哪个 release 是
  Latest，补发旧版本会抢走徽标。workflow 已内置两层防护：
  1) 批次内按版本升序构建（`sort -V`），最新版最后发布；
  2) 构建完成后调用 `make_latest=true` API 把上游最新版本显式设为 latest，
  覆盖任何日期顺序误判。
- **不补历史版本**：定时任务只镜像"比已镜像版本更新"的 release（上游列表按最新
  优先，遇到第一个已镜像版本即停止）；需要历史版本时用 workflow_dispatch 手动
  指定 tag 构建。
- **canary 移动 tag 竞态**：bun canary 每次 commit 都会重新构建发布，SHASUMS256.txt
  与 zip 分两次下载可能来自不同构建导致 sha256 不匹配（不是供应链攻击）。
  更关键的是 bun 的 SHASUMS256.txt 更新**滞后于 zip**（实测滞后 10+ 小时，API
  直取同样滞后）。脚本采用两级校验：Tier1 比对 shas.txt（通过即最强证明）；
  Tier1 不匹配时降级 Tier2——校验解包出的运行时内嵌 `1.4.0-canary` 版本串，
  并打印警告继续（不因 bun 管道缺陷卡死构建）。
- **bun 版本号坑**：`bun --version` 只返回 `1.4.0`，完整 canary 版本号
  （`1.4.0-canary.1+b58cd4685`）要用 `bun --revision` 取。

## 已验证

- 2026-08-05 本地 (Linux aarch64, bun 1.4.0-canary.1) 跑通 `v17.2.9` 全 7 平台构建。
- 2026-08-05 已在 GitHub Actions (ubuntu-latest) 实际端到端跑通：构建 7 平台
  并发布 [v17.2.9 release](https://github.com/nextpoint999/oh-my-pi-bun-canary/releases/tag/v17.2.9)
  （8 个资产含 checksums.txt，exe 已校验 PE32+ AMD64）。
