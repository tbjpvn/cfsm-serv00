#!/bin/sh
# cfsm-serv00.sh — 在 Serv00（FreeBSD，无 root）上安装/管理 cfsm-agent 探针（cf-probe）
# 项目：https://github.com/huilang-me/cfsm-agent
#
# 用法：
#   sh cfsm-serv00.sh                      交互式菜单
#   sh cfsm-serv00.sh install -id=ID -secret=SECRET -url=https://xxx/update [-name=NAME] [-interval=60]
#   sh cfsm-serv00.sh update | start | stop | restart | status | log | uninstall
# 可选环境变量：GHPROXY=https://gh-proxy.example.com   CFP_VERSION=v1.1.0   CFP_DIR=自定义安装目录
#
# 保活原理：用户级 crontab（@reboot + 每 5 分钟检查一次），不需要在 Serv00 面板里设置任何东西。

set -u
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:$PATH"
export PATH

REPO="huilang-me/cfsm-agent"
DIR="${CFP_DIR:-$HOME/.cf-probe}"
BIN="$DIR/cf-probe"
CONF="$DIR/config.conf"
LOG="$DIR/cf-probe.log"
PIDF="$DIR/cf-probe.pid"
KEEP="$DIR/keepalive.sh"
MARK="# cf-probe-keepalive"
GHPROXY="${GHPROXY:-}"
VERSION="${CFP_VERSION:-latest}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERR ] %s\n' "$*" >&2; exit 1; }

# ---------- 交互输入（从 /dev/tty 读，所以 curl | sh 也能用） ----------
ask() {
  _p="$1"; _d="${2:-}"
  if [ -n "$_d" ]; then printf '%s [%s]: ' "$_p" "$_d" >&2; else printf '%s: ' "$_p" >&2; fi
  _a=""
  if ( : </dev/tty ) 2>/dev/null; then read -r _a </dev/tty || _a=""; else read -r _a || _a=""; fi
  [ -n "$_a" ] || _a="$_d"
  printf '%s' "$_a"
}

# ---------- 配置读写 ----------
conf_get() { # key
  [ -f "$CONF" ] || return 0
  grep "^$1=" "$CONF" 2>/dev/null | head -n 1 | cut -d'"' -f2
}

conf_set() { # key value
  case "$2" in *\"*|*\\*|*\$*|*\`*) die "$1 的值不能包含 \" \\ \$ \` 这些字符" ;; esac
  _t="$CONF.tmp.$$"
  grep -v "^$1=" "$CONF" >"$_t" 2>/dev/null || true
  printf '%s="%s"\n' "$1" "$2" >>"$_t"
  mv "$_t" "$CONF"
  chmod 600 "$CONF"
}

conf_init() {
  [ -f "$CONF" ] && return 0
  cat >"$CONF" <<'EOF'
SERVER_ID=""
SECRET=""
WORKER_URL=""
NAME=""
COLLECT_INTERVAL="0"
REPORT_INTERVAL="60"
CT_NODE=""
CU_NODE=""
CM_NODE=""
BD_NODE=""
NODE_1=""
NODE_2=""
NODE_3=""
NODE_4=""
INTERFACE=""
RESET_DAY="1"
CONNECTION_MODE="auto"
PING_MODE="tcp"
AUTO_UPDATE="0"
UPDATE_PROXY=""
CONFIG_MD5="none"
EOF
  chmod 600 "$CONF"
}

# ---------- 进程管理 ----------
is_running() {
  [ -f "$PIDF" ] || return 1
  _pid="$(cat "$PIDF" 2>/dev/null)"
  [ -n "$_pid" ] || return 1
  kill -0 "$_pid" 2>/dev/null || return 1
  ps -p "$_pid" -o command= 2>/dev/null | grep -q "cf-probe"
}

start_probe() {
  [ -x "$BIN" ] || die "未安装，请先执行 install"
  [ -f "$CONF" ] || die "缺少配置文件 $CONF"
  if is_running; then ok "已在运行 (PID $(cat "$PIDF"))"; return 0; fi
  cd "$DIR" || die "无法进入 $DIR"
  : >>"$LOG"
  nohup "$BIN" run -config "$CONF" >>"$LOG" 2>&1 </dev/null &
  echo $! >"$PIDF"
  sleep 3
  if is_running; then
    ok "探针已启动 (PID $(cat "$PIDF"))"
  else
    warn "探针启动后退出了，最近日志："
    tail -n 15 "$LOG" >&2
    return 1
  fi
}

stop_probe() {
  if is_running; then
    kill "$(cat "$PIDF")" 2>/dev/null || true
    sleep 1
    is_running && kill -9 "$(cat "$PIDF")" 2>/dev/null || true
  fi
  # 兜底：清理本用户名下残留的同路径进程
  pkill -u "$(id -u)" -f "$BIN run" 2>/dev/null || true
  rm -f "$PIDF"
  ok "探针已停止"
}

# ---------- 保活（crontab） ----------
write_keepalive() {
  cat >"$KEEP" <<EOF
#!/bin/sh
# cf-probe 保活脚本（由 cfsm-serv00.sh 生成，可被 cron 反复调用）
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin:\$PATH"
DIR="$DIR"
BIN="$BIN"
CONF="$CONF"
LOG="$LOG"
PIDF="$PIDF"
PID="\$(cat "\$PIDF" 2>/dev/null)"
if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null && ps -p "\$PID" -o command= 2>/dev/null | grep -q cf-probe; then
  SZ="\$(wc -c <"\$LOG" 2>/dev/null | tr -d ' ')"
  [ "\${SZ:-0}" -gt 5242880 ] && : >"\$LOG"
  exit 0
fi
cd "\$DIR" || exit 1
nohup "\$BIN" run -config "\$CONF" >>"\$LOG" 2>&1 </dev/null &
echo \$! >"\$PIDF"
EOF
  chmod 700 "$KEEP"
}

cron_installed() {
  command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "$MARK"
}

add_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    warn "没有找到 crontab 命令，无法自动保活。可手动执行：sh $KEEP"
    return 1
  fi
  _t="$DIR/.cron.$$"
  crontab -l 2>/dev/null | grep -v "$MARK" >"$_t" || true
  {
    printf '@reboot %s >/dev/null 2>&1 %s\n' "$KEEP" "$MARK"
    printf '*/5 * * * * %s >/dev/null 2>&1 %s\n' "$KEEP" "$MARK"
  } >>"$_t"
  if crontab "$_t"; then ok "已写入 crontab 保活任务（开机自启 + 每 5 分钟检查）"; else warn "写入 crontab 失败"; fi
  rm -f "$_t"
}

del_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  _t="$DIR/.cron.$$"
  [ -d "$DIR" ] || _t="/tmp/.cfp-cron.$$"
  crontab -l 2>/dev/null | grep -v "$MARK" >"$_t" || true
  if [ -s "$_t" ]; then crontab "$_t"; else crontab -r 2>/dev/null || true; fi
  rm -f "$_t"
}

# ---------- 下载二进制 ----------
download_bin() {
  dl_os="$(uname -s)"; dl_arch="$(uname -m)"
  case "$dl_os" in FreeBSD) dl_o=freebsd ;; Linux) dl_o=linux ;; *) die "不支持的系统: $dl_os" ;; esac
  case "$dl_arch" in
    amd64|x86_64) dl_a=amd64 ;;
    arm64|aarch64) dl_a=arm64 ;;
    i386|i686) dl_a=386 ;;
    *) die "不支持的架构: $dl_arch" ;;
  esac
  dl_asset="${CFP_ASSET:-cf-probe-$dl_o-$dl_a}"
  if [ "$VERSION" = "latest" ]; then dl_path="latest/download"; else dl_path="download/$VERSION"; fi
  dl_url="https://github.com/$REPO/releases/$dl_path/$dl_asset"
  [ -n "$GHPROXY" ] && dl_url="${GHPROXY%/}/$dl_url"
  say "下载: $dl_url"
  dl_tmp="$DIR/cf-probe.new"
  rm -f "$dl_tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 15 -m 300 -o "$dl_tmp" "$dl_url" || die "下载失败（可设置 GHPROXY=代理前缀 后重试）"
  elif command -v fetch >/dev/null 2>&1; then
    fetch -o "$dl_tmp" "$dl_url" || die "下载失败"
  else
    die "需要 curl 或 fetch"
  fi
  chmod +x "$dl_tmp"
  "$dl_tmp" help 2>&1 | grep -q "cf-probe" || { rm -f "$dl_tmp"; die "下载的文件无法执行，可能架构不匹配"; }
  mv -f "$dl_tmp" "$BIN"
  ok "二进制已就绪: $BIN"
}

# ---------- 安装 ----------
do_install() {
  _id=""; _secret=""; _url=""; _name=""; _interval=""
  for arg in "$@"; do
    case "$arg" in
      -id=*|--id=*)             _id="${arg#*=}" ;;
      -secret=*|--secret=*)     _secret="${arg#*=}" ;;
      -url=*|--url=*)           _url="${arg#*=}" ;;
      -name=*|--name=*)         _name="${arg#*=}" ;;
      -interval=*|--interval=*) _interval="${arg#*=}" ;;
      --install-ghproxy=*)      GHPROXY="${arg#*=}" ;;
      --install-version=*)      VERSION="${arg#*=}" ;;
    esac
  done

  mkdir -p "$DIR" || die "无法创建 $DIR"
  chmod 700 "$DIR"
  conf_init

  _prompted=0
  if [ -z "$_id" ] && [ -z "$_secret" ] && [ -z "$_url" ]; then _prompted=1; fi
  if [ "$_prompted" = 1 ]; then
    _id="$(ask 'SERVER_ID（服务器 ID，面板里获取；留空=让服务端自动建号）' "$(conf_get SERVER_ID)")"
    _secret="$(ask 'SECRET（服务器密钥）' "$(conf_get SECRET)")"
    _url="$(ask 'WORKER_URL（上报地址，如 https://xxx.workers.dev/update）' "$(conf_get WORKER_URL)")"
    if [ -z "$_id" ] && [ -z "$_name" ]; then
      _name="$(ask '服务器名称 NAME（自动建号用，可留空）' "$(conf_get NAME)")"
    fi
    [ -n "$_interval" ] || _interval="$(ask '上报间隔（秒）' "$(conf_get REPORT_INTERVAL)")"
  fi
  [ -n "$_interval" ] || _interval="$(conf_get REPORT_INTERVAL)"
  [ -n "$_interval" ] || _interval=60

  [ -n "$_secret" ] || die "SECRET 不能为空"
  case "$_url" in http://*|https://*) ;; *) die "WORKER_URL 必须以 http:// 或 https:// 开头" ;; esac
  case "$_interval" in ''|*[!0-9]*) die "上报间隔必须是数字" ;; esac

  # 先停掉旧进程，再下载新二进制
  is_running && stop_probe

  download_bin

  conf_set SERVER_ID "$_id"
  conf_set SECRET "$_secret"
  conf_set WORKER_URL "$_url"
  [ -n "$_name" ] && conf_set NAME "$_name"
  conf_set REPORT_INTERVAL "$_interval"
  # Serv00 无 root：探针内置的自动更新会尝试写系统目录，所以固定关闭，升级请用本脚本的 update
  conf_set AUTO_UPDATE "0"
  [ -n "$GHPROXY" ] && conf_set UPDATE_PROXY "$GHPROXY"
  ok "配置已写入: $CONF"

  write_keepalive
  add_cron
  start_probe
  show_status
}

do_update() {
  [ -d "$DIR" ] && [ -f "$CONF" ] || die "尚未安装，请先执行 install"
  was=0; is_running && was=1
  [ "$was" = 1 ] && stop_probe
  download_bin
  write_keepalive
  start_probe
}

do_uninstall() {
  _yes="$(ask '确认卸载探针并删除 '"$DIR"' ？(y/N)' 'N')"
  case "$_yes" in y|Y|yes|YES) ;; *) say "已取消"; return 0 ;; esac
  [ -d "$DIR" ] && stop_probe
  del_cron
  case "$DIR" in ""|"/"|"$HOME"|"$HOME/") die "目录异常，拒绝删除: $DIR" ;; esac
  rm -rf "$DIR"
  rm -f /tmp/cf-probe.lock 2>/dev/null || true
  ok "已卸载"
}

show_status() {
  say "------------------------------------------"
  if is_running; then say "状态     : 运行中 (PID $(cat "$PIDF"))"; else say "状态     : 未运行"; fi
  if cron_installed; then say "保活     : crontab 已配置"; else say "保活     : 未配置（crontab 不可用或未安装）"; fi
  if [ -f "$CONF" ]; then
    say "SERVER_ID: $(conf_get SERVER_ID)"
    say "上报地址 : $(conf_get WORKER_URL)"
    say "上报间隔 : $(conf_get REPORT_INTERVAL) 秒"
  fi
  say "安装目录 : $DIR"
  say "配置文件 : $CONF"
  say "日志     : $LOG"
  if [ -f "$LOG" ]; then say "--- 最近日志 ---"; tail -n 5 "$LOG"; fi
  say "------------------------------------------"
}

show_log() { [ -f "$LOG" ] || die "还没有日志"; tail -n 50 "$LOG"; say "(实时查看: tail -f $LOG)"; }

menu() {
  while :; do
    say ""
    say "===== cfsm-agent (Serv00) ====="
    say " 1) 安装 / 重新配置"
    say " 2) 更新探针到最新版"
    say " 3) 查看状态"
    say " 4) 启动"
    say " 5) 停止"
    say " 6) 重启"
    say " 7) 查看日志"
    say " 8) 卸载"
    say " 0) 退出"
    c="$(ask '请选择' '')"
    case "$c" in
      1) do_install ;;
      2) do_update ;;
      3) show_status ;;
      4) start_probe ;;
      5) stop_probe ;;
      6) stop_probe; start_probe ;;
      7) show_log ;;
      8) do_uninstall ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

cmd="${1:-menu}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
  menu)      menu ;;
  install)   do_install "$@" ;;
  update)    do_update ;;
  start)     start_probe ;;
  stop)      stop_probe ;;
  restart)   stop_probe; start_probe ;;
  status)    show_status ;;
  log|logs)  show_log ;;
  uninstall) do_uninstall ;;
  *) die "未知命令: $cmd（可用: install update start stop restart status log uninstall）" ;;
esac
