# omp 镜像发布 Workflow

定时检测 [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi) 的新 release，
一旦上游发布新版本，就用**该 tag 的源码 + 最新 bun canary** 交叉编译全部 7 个平台
的二进制，并发布到**你自己的 GitHub 仓库**。

## 工作原理

```
定时(每6h) ──▶ 查上游最新 releases ──▶ 对比本仓库已发布的同名 releases
                │
                └─ 有新版本(每轮最多3个) ──▶ clone 上游 tag
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

2. 推送后 workflow 会自动按 cron（UTC 每 6 小时）运行；也可以到
   Actions → **Mirror omp releases** → Run workflow 手动触发：
   - `tag`：指定上游 tag 强制构建（如 `v17.2.9`），留空则自动检测
   - `targets`：构建目标，逗号分隔，默认 `all`（7 平台）

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

## 已验证

2026-08-05 在 Linux (aarch64) 上用 bun 1.4.0-canary.1 完整跑通
`bash scripts/build-omp-release.sh v17.2.9`：7 个平台全部构建成功。
