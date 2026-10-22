#!/bin/sh
# 安装 Go：先实测各镜像站速度，取最快者下载 SDK，校验 SHA256 后解压安装；另可挑选最快的 GOPROXY。
set -eu

PREFIX=/usr/local
VERSION=""
FORCE=0
NO_VERIFY=0
PROBE_BYTES=3145728
JSON_URL="https://golang.google.cn/dl/?mode=json"

# 每行：名称|下载基址|额外 curl 参数
MIRRORS='googlecn|https://golang.google.cn/dl|
aliyun|https://mirrors.aliyun.com/golang|
hust|https://mirrors.hust.edu.cn/golang|
cernet|https://mirrors.cernet.edu.cn/golang|
sjtug|https://mirrors.sjtug.sjtu.edu.cn/golang|
nju|https://mirrors.nju.edu.cn/golang|-b bcheck=true
go.dev|https://go.dev/dl|'

# 每行一个 GOPROXY 基址
PROXIES='https://goproxy.cn
https://goproxy.io
https://mirrors.aliyun.com/goproxy
https://proxy.golang.org'

say() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

usage() {
	cat <<'EOF'
用法: install_go.sh [命令] [选项]

命令:
  install     测速 → 下载 → 校验 → 安装 → 配置 PATH 与 GOPROXY（默认）
  speedtest   只测各镜像站当前下载速度
  goproxy     测各 Go 模块代理延迟并写入 go env

选项:
  -v, --version 1.xx.y   指定版本（默认取官方最新稳定版）
  -p, --prefix DIR       GOROOT 的父目录（默认 /usr/local，即装到 /usr/local/go）
  -f, --force            PREFIX/go 已存在时覆盖
      --no-verify        跳过 SHA256 校验
  -h, --help
EOF
}

detect_platform() {
	case "$(uname -s)" in
		Linux) os=linux ;;
		Darwin) os=darwin ;;
		*) die "不支持的系统: $(uname -s)" ;;
	esac
	case "$(uname -m)" in
		x86_64|amd64) goarch=amd64 ;;
		aarch64|arm64) goarch=arm64 ;;
		armv6l|armv7l|arm) goarch=armv6l ;;
		i386|i686) goarch=386 ;;
		riscv64) goarch=riscv64 ;;
		loongarch64) goarch=loong64 ;;
		ppc64le) goarch=ppc64le ;;
		s390x) goarch=s390x ;;
		*) die "无法识别的架构: $(uname -m)" ;;
	esac
}

latest_version() {
	curl -fsSL --max-time 20 "$JSON_URL" 2>/dev/null |
		tr ',' '\n' |
		sed -n 's/.*"version": *"\(go[0-9][0-9.]*\)".*/\1/p' |
		head -n 1
}

# 每秒字节数 → 人类可读
human_rate() {
	awk -v s="$1" 'BEGIN { if (s >= 1048576) printf "%.2f MB/s", s / 1048576; else printf "%.0f KB/s", s / 1024 }'
}

speedtest() {
	file=$1
	ranked=$2
	: > "$ranked"
	while IFS='|' read -r name base extra; do
		[ -n "$name" ] || continue
		url="$base/$file"
		stats=$(curl -sL --max-time 25 -A 'Mozilla/5.0' $extra \
			-r "0-$((PROBE_BYTES - 1))" -o /dev/null \
			-w '%{http_code} %{speed_download}' "$url" 2>/dev/null || echo "000 0")
		code=${stats%% *}
		spd=${stats##* }
		case "$code" in
			200|206) ;;
			*) spd=0 ;;
		esac
		printf '    %-9s %-10s %s\n' "$name" "$code" "$(human_rate "$spd")" >&2
		printf '%s|%s|%s|%s\n' "$spd" "$name" "$base" "$extra" >> "$ranked"
	done <<EOF
$MIRRORS
EOF
	sort -t'|' -k1,1nr "$ranked" -o "$ranked"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx sha256sum; then
		busybox sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	elif command -v python3 >/dev/null 2>&1; then
		python3 - "$1" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
print(h.hexdigest())
PY
	else
		echo ""
	fi
}

expected_sha() {
	file=$1
	base=$2
	s=$(curl -fsSL --max-time 20 "$JSON_URL" 2>/dev/null |
		tr -d ' \n\r\t' |
		tr '{' '\n' |
		grep -F "\"$file\"" |
		grep -o '"sha256":"[0-9a-f]*"' |
		head -n 1 |
		cut -d'"' -f4) || s=""
	if [ -z "$s" ]; then
		s=$(curl -fsSL --max-time 20 -A 'Mozilla/5.0' "$base/$file.sha256" 2>/dev/null |
			grep -o '[0-9a-f]\{64\}' | head -n 1) || s=""
	fi
	echo "$s"
}

ensure_path() {
	line="export PATH=\"$PREFIX/go/bin:\$PATH\""
	if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
		printf '%s\n' "$line" > /etc/profile.d/go.sh
	fi
	if [ -w "$HOME" ] || [ ! -e "$HOME/.profile" ]; then
		grep -qF "$PREFIX/go/bin" "$HOME/.profile" 2>/dev/null ||
			printf '%s\n' "$line" >> "$HOME/.profile"
	fi
}

install() {
	[ -n "$VERSION" ] || VERSION=$(latest_version)
	[ -n "$VERSION" ] || die "无法获取最新版本号，请用 --version 指定（如 --version 1.24.5）"
	VERSION=${VERSION#go}
	file="go$VERSION.$os-$goarch.tar.gz"
	say "目标: $file"

	tmpdir=${TMPDIR:-/tmp}
	ranked="$tmpdir/go-install-rank.$$"
	tmp="$tmpdir/$file"
	trap 'rm -f "$ranked"' EXIT INT TERM

	say "镜像测速（取前 3MB）"
	speedtest "$file" "$ranked"
	best=$(head -n 1 "$ranked")
	[ "${best%%|*}" -gt 0 ] || die "所有镜像均不可用，检查网络"

	ok=0
	while IFS='|' read -r spd name base extra; do
		[ "${spd:-0}" -gt 0 ] || continue
		say "从 $name 下载（$(human_rate "$spd")）"
		if curl -fL --retry 2 -C - -A 'Mozilla/5.0' $extra -o "$tmp" "$base/$file"; then
			ok=1
			break
		fi
		say "$name 下载失败，换下一个镜像"
	done < "$ranked"
	[ "$ok" = 1 ] || die "下载失败"

	if [ "$NO_VERIFY" = 0 ]; then
		expect=$(expected_sha "$file" "$base")
		actual=$(sha256_of "$tmp")
		if [ -z "$expect" ] || [ -z "$actual" ]; then
			say "警告: 无法取得或计算 SHA256，跳过校验"
		elif [ "$expect" != "$actual" ]; then
			rm -f "$tmp"
			die "SHA256 不匹配（期望 $expect，实际 $actual），已删除下载文件"
		else
			say "SHA256 校验通过"
		fi
	fi

	if [ -e "$PREFIX/go" ]; then
		[ "$FORCE" = 1 ] || die "$PREFIX/go 已存在，加 --force 覆盖"
		[ -f "$PREFIX/go/VERSION" ] || die "$PREFIX/go 不是 Go 安装目录，拒绝覆盖"
		mkdir -p "$PREFIX/go.old"
		mv "$PREFIX/go" "$PREFIX/go.old/go-$(date +%Y%m%d%H%M%S)"
		say "旧版本已移到 $PREFIX/go.old"
	fi

	mkdir -p "$PREFIX"
	tar -C "$PREFIX" -xzf "$tmp"
	rm -f "$tmp"

	ensure_path
	"$PREFIX/go/bin/go" version
	say "已安装到 $PREFIX/go，PATH 已写入 /etc/profile.d/go.sh 与 ~/.profile（当前 shell 可用: export PATH=\"$PREFIX/go/bin:\$PATH\"）"
}

goproxy() {
	say "Go 模块代理测速"
	best=""
	best_t=""
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		stats=$(curl -s -o /dev/null --max-time 10 -w '%{http_code} %{time_total}' \
			"$p/github.com/pkg/errors/@v/list" 2>/dev/null || echo "000 0")
		code=${stats%% *}
		t=${stats##* }
		case "$code" in
			200) printf '    %-36s %ss\n' "$p" "$t" ;;
			*) printf '    %-36s 不可用(%s)\n' "$p" "$code"; t=0 ;;
		esac
		if [ "$t" != 0 ] && { [ -z "$best_t" ] || awk -v a="$t" -v b="$best_t" 'BEGIN{exit !(a<b)}'; }; then
			best=$p
			best_t=$t
		fi
	done <<EOF
$PROXIES
EOF
	[ -n "$best" ] || die "没有可用的 Go 模块代理"

	second=""
	while IFS= read -r p; do
		[ -n "$p" ] && [ "$p" != "$best" ] || continue
		if curl -fsS -o /dev/null --max-time 10 "$p/github.com/pkg/errors/@v/list" 2>/dev/null; then
			second=$p
			break
		fi
	done <<EOF
$PROXIES
EOF

	value="$best"
	[ -n "$second" ] && value="$best,$second"
	value="$value,direct"

	gobin=""
	if command -v go >/dev/null 2>&1; then
		gobin=$(command -v go)
	elif [ -x "$PREFIX/go/bin/go" ]; then
		gobin="$PREFIX/go/bin/go"
	fi
	[ -n "$gobin" ] || die "找不到 go 命令，先执行 install_go.sh install"

	"$gobin" env -w GOPROXY="$value"
	say "已写入 GOPROXY=$value"
	"$gobin" env GOPROXY
}

command=install
while [ $# -gt 0 ]; do
	case "$1" in
		install|speedtest|goproxy) command=$1 ;;
		-v|--version) VERSION=$2; shift ;;
		-p|--prefix) PREFIX=$2; shift ;;
		-f|--force) FORCE=1 ;;
		--no-verify) NO_VERIFY=1 ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知参数: $1（--help 查看用法）" ;;
	esac
	shift
done

detect_platform

case "$command" in
	speedtest)
		[ -n "$VERSION" ] || VERSION=$(latest_version)
		VERSION=${VERSION#go}
		file="go$VERSION.$os-$goarch.tar.gz"
		say "测速对象: $file"
		ranked=${TMPDIR:-/tmp}/go-install-rank.$$
		speedtest "$file" "$ranked"
		say "排名（快的在前）"
		awk -F'|' '{ if ($1 >= 1048576) r = sprintf("%.2f MB/s", $1 / 1048576); else r = sprintf("%.0f KB/s", $1 / 1024); printf "    %-9s %s\n", $2, r }' "$ranked"
		rm -f "$ranked"
		;;
	goproxy) goproxy ;;
	install) install ;;
esac
