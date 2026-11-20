#!/usr/bin/env bash
# install-filebrowser-quantum.sh
# Installs / upgrades / uninstalls FileBrowser Quantum (gtsteffaniak/filebrowser)
# as a systemd service, and wires it into an existing nginx (or angie/openresty)
# under a subpath such as /files. Built with DietPi in mind, works on Debian-likes.
#
# Usage:
#   sudo ./install-filebrowser-quantum.sh [options]
#
# Options:
#   --path DIR          Folder to expose (default: /mnt/dietpi_userdata, else /srv/files)
#   --subpath PATH      URL subpath behind nginx (default: /files)
#   --port N            Local port for FileBrowser (default: first free from 8090)
#   --user NAME         Service user (default: dietpi if it exists, else 'filebrowser')
#   --external-url URL  Public URL, e.g. https://example.com (used for share links)
#   --nginx-conf FILE   Server-block file to hook into (skip auto-detection)
#   --no-nginx          Don't touch nginx; serve FileBrowser directly on its port
#   --uninstall         Remove service, binary and nginx hook (keeps data/config)
#   --purge             With --uninstall, also delete /opt/filebrowser (config + DB)
#   -y, --yes           Don't ask for confirmation
#   -h, --help          Show this help

set -euo pipefail

# ---------- defaults ----------
INSTALL_DIR=/opt/filebrowser
BIN=/usr/local/bin/filebrowser
SERVICE=/etc/systemd/system/filebrowser.service
MARKER="# managed-by: filebrowser-quantum-installer"
RELEASE_URL="https://github.com/gtsteffaniak/filebrowser/releases/latest/download"

FILES_PATH=""
SUBPATH="/files"
PORT=""
RUN_USER=""
EXTERNAL_URL=""
NGINX_CONF=""
USE_NGINX=auto
UNINSTALL=0
PURGE=0
ASSUME_YES=0

# Filled in by detection
NGINX_BIN=""
NGINX_SVC=""
NGINX_HOOK_MODE=""   # "dropin" (dir auto-included in server block) or "include"
NGINX_SNIPPET=""
NGINX_TARGET=""

# ---------- helpers ----------
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_info=""; c_ok=""; c_warn=""; c_err=""; c_off=""; }
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok} ✓${c_off} $*"; }
warn() { echo "${c_warn} !${c_off} $*" >&2; }
die()  { echo "${c_err} ✗ $*${c_off}" >&2; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

confirm() {
  (( ASSUME_YES )) && return 0
  local reply
  read -r -p "$1 [y/N] " reply </dev/tty || return 1
  [[ $reply =~ ^[Yy] ]]
}

port_in_use() {
  local p=$1
  if command -v ss >/dev/null; then
    ss -ltnH "( sport = :$p )" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}

# ---------- detection ----------
detect_arch() {
  local a
  a=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$a" in
    amd64|x86_64)          echo linux-amd64-filebrowser ;;
    arm64|aarch64)         echo linux-arm64-filebrowser ;;
    armhf|armv7l|armv7*)   echo linux-armv7-filebrowser ;;
    riscv64)               echo linux-riscv64-filebrowser ;;
    armel|armv6l)          die "ARMv6 (e.g. Pi Zero/1) isn't supported by FileBrowser Quantum releases." ;;
    *)                     die "Unsupported architecture: $a" ;;
  esac
}

detect_nginx() {
  local b
  for b in nginx angie openresty; do
    if command -v "$b" >/dev/null 2>&1; then NGINX_BIN=$(command -v "$b"); break; fi
  done
  [[ -n $NGINX_BIN ]] || return 1

  NGINX_SVC=$(basename "$NGINX_BIN")
  local ver
  ver=$("$NGINX_BIN" -v 2>&1 | head -n1)
  ok "Found web server: $ver ($NGINX_BIN)"
  if command -v dpkg-query >/dev/null; then
    local pkg
    pkg=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nginx*' 'angie*' 'openresty*' 2>/dev/null \
          | awk '$1=="ii"{print $2}' \
          | grep -E '^(nginx|nginx-(full|light|extras|core)|angie|openresty)$' \
          | tr '\n' ' ' || true)
    [[ -n $pkg ]] && ok "Installed package(s): $pkg"
  fi
  if systemctl is-active --quiet "$NGINX_SVC" 2>/dev/null; then
    ok "$NGINX_SVC service is running"
  else
    warn "$NGINX_SVC is installed but its service isn't running"
  fi
  return 0
}

# Full effective config, so we see every included file
nginx_dump() { "$NGINX_BIN" -T 2>/dev/null; }

# Files (from `nginx -T`) that contain a server block, excluding the main conf.
nginx_server_files() {
  nginx_dump | awk '
    /^# configuration file / { f=$4; sub(/:$/,"",f); next }
    f != "" && /^[[:space:]]*server[[:space:]]*\{/ { print f }
  ' | sort -u
}

pick_nginx_target() {
  local dump
  dump=$(nginx_dump) || die "'$NGINX_BIN -T' failed - your nginx config has errors. Fix them first (run: $NGINX_BIN -t)."

  # 1) Existing conflict?
  if grep -Eq "location[[:space:]]+[=^~]*[[:space:]]*${SUBPATH%/}/?[[:space:]]*\{" <<<"$dump" \
     && ! grep -q "$MARKER" <<<"$dump"; then
    die "nginx already has a 'location $SUBPATH' block. Pick another with --subpath."
  fi

  if [[ -n $NGINX_CONF ]]; then
    [[ -f $NGINX_CONF ]] || die "--nginx-conf $NGINX_CONF does not exist"
    NGINX_HOOK_MODE=include; NGINX_TARGET=$(readlink -f "$NGINX_CONF"); return
  fi

  # 2) DietPi: its default site includes /etc/nginx/sites-dangerous/*.conf inside
  #    the server block, so a drop-in file there needs no edits to other files.
  if grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/sites-dangerous/\*\.conf' <<<"$dump" \
     && [[ -d /etc/nginx/sites-dangerous ]]; then
    NGINX_HOOK_MODE=dropin
    NGINX_SNIPPET=/etc/nginx/sites-dangerous/filebrowser.conf
    ok "DietPi nginx layout detected (sites-dangerous drop-in)"
    return
  fi

  # 3) Generic: choose a server-block file. Prefer one listening on 443, then
  #    default_server, then the first one found.
  local files f best=""
  mapfile -t files < <(nginx_server_files)
  (( ${#files[@]} )) || die "No server blocks found in nginx config. Use --nginx-conf or --no-nginx."
  for f in "${files[@]}"; do grep -Eq 'listen[^;]*443' "$f" 2>/dev/null && { best=$f; break; }; done
  if [[ -z $best ]]; then
    for f in "${files[@]}"; do grep -q 'default_server' "$f" 2>/dev/null && { best=$f; break; }; done
  fi
  [[ -n $best ]] || best=${files[0]}
  (( ${#files[@]} > 1 )) && warn "Multiple server-block files found: ${files[*]}"
  NGINX_HOOK_MODE=include
  NGINX_TARGET=$(readlink -f "$best")
}

# ---------- nginx changes ----------
write_nginx_snippet() {
  local sp=${SUBPATH%/}
  cat >"$1" <<EOF
$MARKER
# FileBrowser Quantum at $sp/  ->  127.0.0.1:$PORT
location = $sp {
    return 301 $sp/;
}

# Public share links (FileBrowser handles their auth itself)
location $sp/public/ {
    proxy_pass http://127.0.0.1:$PORT$sp/public/;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
}

location $sp/ {
    proxy_pass http://127.0.0.1:$PORT$sp/;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;          # needed for live updates (SSE)
    proxy_request_buffering off;  # stream big uploads instead of spooling to disk
    proxy_read_timeout 1h;
    client_max_body_size 10G;
}
EOF
}

# Insert an include line right after every top-level `server {` in a file.
# (A server-level `return 301` redirect still wins, so redirect-only blocks are harmless.)
insert_include() {
  local file=$1 line=$2
  awk -v inc="$line" -v mark="$MARKER" '
    {
      code=$0; sub(/#.*/, "", code)
      print
      if (depth == 0 && code ~ /^[[:space:]]*server[[:space:]]*\{/) {
        print "    " inc " " mark; n++
      }
      o=gsub(/\{/, "{", code); c=gsub(/\}/, "}", code); depth += o - c
    }
    END { if (n == 0) exit 3 }
  ' "$file"
}

hook_nginx() {
  local backup_dir=$INSTALL_DIR/backups ts
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup_dir"

  if [[ $NGINX_HOOK_MODE == dropin ]]; then
    write_nginx_snippet "$NGINX_SNIPPET"
  else
    local snipdir=/etc/nginx/snippets
    [[ -d /etc/nginx ]] || snipdir=$(dirname "$("$NGINX_BIN" -V 2>&1 | grep -o -- '--conf-path=[^ ]*' | cut -d= -f2)")/snippets
    mkdir -p "$snipdir"
    NGINX_SNIPPET=$snipdir/filebrowser.conf
    write_nginx_snippet "$NGINX_SNIPPET"

    if grep -q "include $NGINX_SNIPPET;" "$NGINX_TARGET"; then
      ok "nginx already includes $NGINX_SNIPPET in $NGINX_TARGET"
    else
      # Back up OUTSIDE nginx dirs, so the backup is never loaded by an include glob
      cp -a "$NGINX_TARGET" "$backup_dir/$(basename "$NGINX_TARGET").$ts"
      local tmp; tmp=$(mktemp)
      if ! insert_include "$NGINX_TARGET" "include $NGINX_SNIPPET;" >"$tmp"; then
        rm -f "$tmp"; die "Couldn't find a 'server {' line in $NGINX_TARGET. Add 'include $NGINX_SNIPPET;' to your server block by hand."
      fi
      cat "$tmp" >"$NGINX_TARGET"; rm -f "$tmp"   # cat keeps owner/perms/symlink
      ok "Added include to $NGINX_TARGET (backup in $backup_dir)"
    fi
  fi

  if "$NGINX_BIN" -t >/dev/null 2>&1; then
    ok "nginx config test passed"
    if systemctl is-active --quiet "$NGINX_SVC" 2>/dev/null; then
      systemctl reload "$NGINX_SVC"; ok "Reloaded $NGINX_SVC"
    else
      warn "$NGINX_SVC isn't running; start it with: systemctl start $NGINX_SVC"
    fi
  else
    warn "nginx config test FAILED - rolling back:"
    "$NGINX_BIN" -t 2>&1 | sed 's/^/    /' >&2 || true
    rm -f "$NGINX_SNIPPET"
    if [[ $NGINX_HOOK_MODE == include ]]; then
      local last; last=$(ls -1t "$backup_dir/$(basename "$NGINX_TARGET")".* 2>/dev/null | head -n1 || true)
      [[ -n $last ]] && cat "$last" >"$NGINX_TARGET"
    fi
    die "nginx left unchanged. FileBrowser itself is installed and running on port $PORT."
  fi
}

unhook_nginx() {
  local f
  for f in /etc/nginx/sites-dangerous/filebrowser.conf /etc/nginx/snippets/filebrowser.conf; do
    [[ -f $f ]] && grep -q "$MARKER" "$f" && { rm -f "$f"; ok "Removed $f"; }
  done
  # Remove include lines we added, wherever they are
  local files
  mapfile -t files < <(grep -rlF "$MARKER" /etc/nginx 2>/dev/null || true)
  for f in "${files[@]}"; do
    f=$(readlink -f "$f")
    sed -i "\|$MARKER|d" "$f"; ok "Removed include from $f"
  done
  if [[ -n $NGINX_BIN ]] && "$NGINX_BIN" -t >/dev/null 2>&1; then
    systemctl reload "$NGINX_SVC" 2>/dev/null || true
  fi
}

# ---------- filebrowser ----------
download_binary() {
  local asset tmpd
  asset=$(detect_arch)
  tmpd=$(mktemp -d)
  info "Downloading $asset (latest release)"
  curl -fL --retry 3 --progress-bar -o "$tmpd/filebrowser" "$RELEASE_URL/$asset" \
    || { rm -rf "$tmpd"; die "Download failed from $RELEASE_URL/$asset"; }
  # Sanity check: must be an ELF binary, not an HTML error page
  [[ $(head -c4 "$tmpd/filebrowser" | od -An -c | tr -d ' ') == '177ELF' ]] \
    || { rm -rf "$tmpd"; die "Downloaded file isn't a Linux binary."; }
  install -m 0755 "$tmpd/filebrowser" "$BIN"
  rm -rf "$tmpd"
  ok "Installed $BIN"
}

write_config() {
  local cfg=$INSTALL_DIR/config.yaml
  {
    echo "http:"
    echo "  port: $PORT"
    if [[ $USE_NGINX == yes ]]; then
      echo "  baseURL: \"${SUBPATH%/}\""
      echo "  trustProxyHeaders: true"
    fi
    [[ -n $EXTERNAL_URL ]] && echo "  externalUrl: \"$EXTERNAL_URL\""
    echo "server:"
    echo "  sources:"
    echo "    - path: $FILES_PATH"
    echo "      config:"
    echo "        defaultEnabled: true"
    echo "auth:"
    echo "  adminUsername: admin"
  } >"$cfg"
  chown "$RUN_USER": "$cfg"; chmod 640 "$cfg"
  ok "Wrote $cfg"
}

write_service() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=FileBrowser Quantum
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN -c $INSTALL_DIR/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "Wrote $SERVICE"
}

show_initial_password() {
  local since=$1 pw=""
  info "Waiting for the initial admin password in the logs..."
  for _ in $(seq 1 20); do
    pw=$(journalctl -u filebrowser --since "$since" --no-pager 2>/dev/null \
         | grep -i "initial admin password" | tail -n1 || true)
    [[ -n $pw ]] && break
    sleep 1
  done
  if [[ -n $pw ]]; then
    echo; echo "    ${c_ok}${pw#*: }${c_off}"; echo
    echo "    Username: admin  (you'll be asked to change the password on first login)"
  else
    warn "Didn't see the password yet. Check: journalctl -u filebrowser | grep -i 'initial admin password'"
  fi
}

# ---------- main flows ----------
do_uninstall() {
  info "Uninstalling FileBrowser Quantum"
  confirm "Remove the service, binary and nginx hook?" || die "Aborted."
  systemctl disable --now filebrowser 2>/dev/null || true
  rm -f "$SERVICE" "$BIN"; systemctl daemon-reload
  ok "Removed service and binary"
  detect_nginx >/dev/null 2>&1 || true
  unhook_nginx
  if (( PURGE )); then rm -rf "$INSTALL_DIR"; ok "Deleted $INSTALL_DIR"
  else ok "Kept $INSTALL_DIR (config + database). Use --purge to delete it."; fi
}

do_install() {
  command -v curl >/dev/null || { info "Installing curl"; apt-get update -qq && apt-get install -y -qq curl; }
  command -v systemctl >/dev/null || die "systemd is required."

  local upgrade=0
  [[ -x $BIN && -f $INSTALL_DIR/config.yaml ]] && upgrade=1

  # --- service user ---
  if [[ -z $RUN_USER ]]; then
    if id dietpi >/dev/null 2>&1; then RUN_USER=dietpi; else RUN_USER=filebrowser; fi
  fi

  if (( upgrade )); then
    info "Existing install found - upgrading the binary, keeping config and database"
    PORT=$(awk '/^http:/{h=1;next} /^[^[:space:]]/{h=0} h&&/^[[:space:]]+port:/{print $2;exit}' "$INSTALL_DIR/config.yaml")
    RUN_USER=$(awk -F= '/^User=/{print $2}' "$SERVICE" 2>/dev/null || echo "$RUN_USER")
    confirm "Upgrade FileBrowser Quantum now?" || die "Aborted."
    systemctl stop filebrowser 2>/dev/null || true
    download_binary
    systemctl start filebrowser
    ok "Upgraded and restarted (port $PORT)"
    return
  fi

  # --- files path ---
  if [[ -z $FILES_PATH ]]; then
    if [[ -d /mnt/dietpi_userdata ]]; then FILES_PATH=/mnt/dietpi_userdata; else FILES_PATH=/srv/files; fi
  fi

  # --- port ---
  if [[ -z $PORT ]]; then
    PORT=8090
    while port_in_use "$PORT"; do PORT=$((PORT + 1)); done
  elif port_in_use "$PORT"; then
    die "Port $PORT is already in use."
  fi

  # --- nginx ---
  if [[ $USE_NGINX != no ]]; then
    if detect_nginx; then
      USE_NGINX=yes
      [[ $SUBPATH == /* && $SUBPATH != / ]] || die "--subpath must start with / and not be just '/'."
      pick_nginx_target
    else
      [[ $USE_NGINX == yes ]] && die "nginx not found."
      for other in apache2 lighttpd caddy; do
        command -v "$other" >/dev/null 2>&1 && warn "Found $other - this script only configures nginx. You'll need to proxy to port $PORT yourself."
      done
      warn "No nginx found - FileBrowser will be served directly on port $PORT."
      USE_NGINX=no
    fi
  fi

  # --- summary ---
  echo
  info "Plan:"
  echo "    Architecture : $(detect_arch)"
  echo "    Binary       : $BIN"
  echo "    Config + DB  : $INSTALL_DIR"
  echo "    Files folder : $FILES_PATH"
  echo "    Runs as      : $RUN_USER"
  echo "    Local port   : $PORT"
  if [[ $USE_NGINX == yes ]]; then
    echo "    nginx        : ${SUBPATH%/}/ via $( [[ $NGINX_HOOK_MODE == dropin ]] && echo "$NGINX_SNIPPET (drop-in)" || echo "include in $NGINX_TARGET")"
  else
    echo "    nginx        : not used"
  fi
  [[ -n $EXTERNAL_URL ]] && echo "    External URL : $EXTERNAL_URL"
  echo
  confirm "Proceed?" || die "Aborted."

  # --- do it ---
  if ! id "$RUN_USER" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR" "$RUN_USER"
    ok "Created system user $RUN_USER"
  fi
  mkdir -p "$INSTALL_DIR"
  chown "$RUN_USER": "$INSTALL_DIR"
  if [[ ! -d $FILES_PATH ]]; then
    mkdir -p "$FILES_PATH"; chown "$RUN_USER": "$FILES_PATH"; ok "Created $FILES_PATH"
  elif ! runuser -u "$RUN_USER" -- test -r "$FILES_PATH" -a -x "$FILES_PATH"; then
    warn "$RUN_USER can't read $FILES_PATH - FileBrowser won't see your files until permissions are fixed."
  elif ! runuser -u "$RUN_USER" -- test -w "$FILES_PATH"; then
    warn "$RUN_USER has read-only access to $FILES_PATH (uploads/edits will fail)."
  fi

  if ! command -v ffmpeg >/dev/null; then
    if confirm "Install ffmpeg for video thumbnails? (optional, ~100MB)"; then
      apt-get install -y -qq ffmpeg && ok "Installed ffmpeg"
    fi
  fi

  download_binary
  write_config
  write_service

  local since; since=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl enable --now filebrowser >/dev/null 2>&1
  sleep 2
  systemctl is-active --quiet filebrowser \
    || { journalctl -u filebrowser -n 30 --no-pager >&2; die "FileBrowser failed to start (log above)."; }
  ok "filebrowser service is running"

  [[ $USE_NGINX == yes ]] && hook_nginx

  show_initial_password "$since"

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  if [[ $USE_NGINX == yes ]]; then
    ok "Open: http://${ip:-your-server}${SUBPATH%/}/"
    echo "    Tip: block port $PORT from your LAN (e.g. 'ufw deny $PORT') so it's only reachable via nginx,"
    echo "         since trustProxyHeaders is enabled."
  else
    ok "Open: http://${ip:-your-server}:$PORT/"
  fi
  echo "    Logs:      journalctl -u filebrowser -f"
  echo "    Config:    $INSTALL_DIR/config.yaml  (then: systemctl restart filebrowser)"
  echo "    Upgrade:   re-run this script"
}

main() {
  while (( $# )); do
    case "$1" in
      --path)         FILES_PATH=${2:?}; shift ;;
      --subpath)      SUBPATH=${2:?}; shift ;;
      --port)         PORT=${2:?}; shift ;;
      --user)         RUN_USER=${2:?}; shift ;;
      --external-url) EXTERNAL_URL=${2%/}; shift ;;
      --nginx-conf)   NGINX_CONF=${2:?}; USE_NGINX=yes; shift ;;
      --no-nginx)     USE_NGINX=no ;;
      --uninstall)    UNINSTALL=1 ;;
      --purge)        PURGE=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      -h|--help)      usage ;;
      *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [[ $SUBPATH == /* ]] || SUBPATH="/$SUBPATH"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 ...)"

  if (( UNINSTALL )); then do_uninstall; else do_install; fi
}

# Allow sourcing for tests
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
