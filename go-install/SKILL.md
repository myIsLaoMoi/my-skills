---
name: go-install
description: 在 Linux/macOS 上安装 Go 并解决下载慢的问题。当需要安装或升级 Go、配置 GOROOT/PATH、或因 proxy.golang.org 不可达导致 go mod download / go get / go install 卡住时使用；脚本会实测各国内镜像站速度后选最快的下载 SDK，校验 SHA256，并挑选最快的 GOPROXY。
---

# 安装 Go（含镜像测速）

脚本 `install_go.sh` 在本技能目录下，纯 POSIX sh + curl，无需 bash/python。

## 快速开始

```bash
SKILL=~/.aicode/skills/go-install
sh "$SKILL/install_go.sh"              # 测速 → 下载 → 校验 → 安装 → 配 PATH + GOPROXY
sh "$SKILL/install_go.sh" speedtest    # 只测各镜像当前速度，不装任何东西
sh "$SKILL/install_go.sh" goproxy      # 只测 Go 模块代理并写 go env
```

装完当前 shell 里要显式加一次 PATH：

```bash
export PATH=/usr/local/go/bin:$PATH
go version
go env GOPROXY
```

新开的登录 shell 会自动生效（`/etc/profile.d/go.sh` + `~/.profile`）。

## 常用参数

| 参数 | 说明 |
|---|---|
| `-v, --version 1.24.5` | 指定版本，默认取官方最新稳定版 |
| `-p, --prefix DIR` | GOROOT 父目录，默认 `/usr/local`（即装到 `/usr/local/go`） |
| `-f, --force` | `PREFIX/go` 已存在时覆盖，旧版本移到 `PREFIX/go.old/go-<时间戳>` |
| `--no-verify` | 跳过 SHA256 校验 |

## 脚本做了什么

1. `uname -m` 映射到 Go 的 `amd64/arm64/armv6l/386/riscv64/loong64`，`uname -s` 决定 `linux/darwin`。
2. 版本未指定时读 `https://golang.google.cn/dl/?mode=json` 取第一个 `"version"`（即最新稳定版）。
3. 对每个镜像发 `Range: 0-3MB` 请求，取 `speed_download` 排序，快的在前；下载时按此顺序回退，失败自动换下一个。
4. SHA256 期望值优先取官方 JSON，取不到再取镜像的 `<file>.sha256`；校验失败直接删除文件并退出。
5. 解压到 `PREFIX`，然后测 `GOPROXY` 候选（goproxy.cn / goproxy.io / 阿里云 / proxy.golang.org），写入「最快, 次快, direct」。

## 镜像站（脚本内置，均已实测可用）

| 名称 | 基址 |
|---|---|
| googlecn | `https://golang.google.cn/dl` |
| aliyun | `https://mirrors.aliyun.com/golang` |
| hust | `https://mirrors.hust.edu.cn/golang` |
| cernet | `https://mirrors.cernet.edu.cn/golang` |
| sjtug | `https://mirrors.sjtug.sjtu.edu.cn/golang` |
| nju | `https://mirrors.nju.edu.cn/golang`（需 `-b bcheck=true`） |
| go.dev | `https://go.dev/dl`（官方兜底） |

各站速度随网络与时段变化，不要硬编码结论，每次都让脚本重新测。若某个站长期不通，直接从脚本 `MIRRORS` 里删掉一行，或新增 `名称|基址|额外 curl 参数`。

## Go 模块下载慢（不是 SDK 慢）

脚本会把 GOPROXY 配成最快的镜像，等价于手动执行：

```bash
go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct
```

配套几项：

- 私有仓库不走代理：`go env -w GOPRIVATE=git.example.com,github.com/yourorg/*`（GONOPROXY/GONOSUMDB 会自动继承）。
- 卡在 `verifying`：镜像已代理解析 sumdb，通常换镜像即可；内网可临时 `go env -w GOSUMDB=off`。
- 定位卡在哪：`go mod download -x` 打印实际请求的 URL。
- 反复构建/CI：`go mod download` 预热 `$GOMODCACHE`，或 `go mod vendor` + `GOFLAGS=-mod=vendor` 完全离线。
- 离线：`GOPROXY=off` 只用本地 `$GOMODCACHE/cache/download`。
- 新版 Go 会因 `go.mod` 的 `toolchain` 指令自动下载工具链，卡住时先 `GOTOOLCHAIN=local`。

## 验证

```bash
/usr/local/go/bin/go version            # 版本与架构要对得上
/usr/local/go/bin/go env GOROOT GOPROXY
cd /tmp && mkdir -p h && cd h && go mod init h && go get github.com/pkg/errors   # 端到端拉包
```

## 注意

- 安装 Go 会写 `/usr/local`、`/etc/profile.d/go.sh` 与 `~/.profile`，属于系统级改动；在受限容器里先确认可写。
- `--force` 只允许覆盖带 `VERSION` 文件的目录，避免误删非 Go 目录。
- `PREFIX/go.old/` 下的旧版本不会被自动清理，确认新版本可用后可自行删除。
