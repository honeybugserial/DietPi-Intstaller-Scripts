#!/usr/bin/env bash
# install-cockpit-filesharing.sh
# Installs Cockpit (minimal, DietPi-friendly) plus the 45Drives plugins:
#   - cockpit-file-sharing  (Samba + NFS share management)
#   - cockpit-identities    (users, groups, Samba passwords)   [optional]
# and prepares Samba for the plugin (include = registry), with backup + validation.
#
# Usage:
#   sudo ./install-cockpit-filesharing.sh [options]
#
# Options:
#   --port N           Port for Cockpit (default: 9090)
#   --no-identities    Skip the cockpit-identities plugin
#   --no-samba-setup   Don't touch smb.conf (you'll click "Fix" in the UI instead)
#   --uninstall        Remove Cockpit and the plugins (leaves Samba and smb.conf alone)
#   -y, --yes          Don't ask for confirmation
#   -h, --help         Show this help

set -euo pipefail

PORT=9090
WITH_IDENTITIES=1
SAMBA_SETUP=1
UNINSTALL=0
ASSUME_YES=0

SMB_CONF=/etc/samba/smb.conf
BACKUP_DIR=/root/cockpit-installer-backups
MARKER="# added-by: cockpit-filesharing-installer"

# Known-good fallbacks, used only if the latest release can't be looked up.
declare -A FALLBACK_TAG=( [cockpit-file-sharing]=v4.6.3 )
declare -A FALLBACK_VER=( [cockpit-file-sharing]=4.6.3-1 )

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

port_in_use() { ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .; }

apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@"; }

# ---------- detection ----------
detect_os() {
  [[ -r /etc/os-release ]] || die "Can't read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-unknown}
  CODENAME=${VERSION_CODENAME:-}
  [[ -n $CODENAME ]] || die "Couldn't determine the OS codename."
  IS_DIETPI=0; [[ -d /boot/dietpi || -x /boot/dietpi/dietpi-software ]] && IS_DIETPI=1
  ok "OS: ${PRETTY_NAME:-$OS_ID} ($CODENAME)$( (( IS_DIETPI )) && echo ', DietPi detected')"
}

# Order of preference for which 45Drives .deb build to use on this system.
deb_flavours() {
  case "$CODENAME" in
    trixie|forky|sid) echo "trixie bookworm noble jammy" ;;
    bookworm)         echo "bookworm trixie jammy" ;;
    bullseye)         echo "focal bookworm" ;;
    noble|oracular|plucky) echo "noble jammy bookworm" ;;
    jammy)            echo "jammy focal" ;;
    focal)            echo "focal" ;;
    *)                echo "$CODENAME trixie bookworm jammy" ;;
  esac
}

# Print "<tag> <url-of-best-deb>" for a 45Drives repo.
find_release_deb() {
  local repo=$1 tag html urls flav url
  tag=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/45Drives/$repo/releases/latest" 2>/dev/null | sed -n 's|.*/releases/tag/||p')
  if [[ -n $tag ]]; then
    html=$(curl -fsSL "https://github.com/45Drives/$repo/releases/expanded_assets/$tag" 2>/dev/null || true)
    urls=$(grep -o "releases/download/[^\"]*_all\.deb" <<<"$html" | sort -u || true)
    for flav in $(deb_flavours); do
      url=$(grep -m1 -- "${flav}_all\.deb" <<<"$urls" || true)
      if [[ -n $url ]]; then echo "$tag https://github.com/45Drives/$repo/$url"; return 0; fi
    done
    # Generic (no codename) build, if they ship one
    url=$(grep -m1 -E -- '-[0-9]+_all\.deb' <<<"$urls" || true)
    [[ -n $url ]] && { echo "$tag https://github.com/45Drives/$repo/$url"; return 0; }
  fi
  # Fallback to pinned version
  if [[ -n ${FALLBACK_TAG[$repo]:-} ]]; then
    for flav in $(deb_flavours); do
      case $flav in bookworm|trixie|focal|jammy) ;; *) continue ;; esac
      echo "${FALLBACK_TAG[$repo]} https://github.com/45Drives/$repo/releases/download/${FALLBACK_TAG[$repo]}/${repo}_${FALLBACK_VER[$repo]}${flav}_all.deb"
      return 0
    done
  fi
  return 1
}

install_45drives_deb() {
  local repo=$1 res tag url tmpd
  info "Looking up latest $repo release"
  res=$(find_release_deb "$repo") || { warn "Couldn't find a .deb for $repo on this OS - skipping."; return 1; }
  tag=${res%% *}; url=${res#* }
  ok "$repo $tag -> $(basename "$url")"
  tmpd=$(mktemp -d)
  curl -fL --retry 3 --progress-bar -o "$tmpd/$(basename "$url")" "$url" \
    || { rm -rf "$tmpd"; warn "Download failed: $url"; return 1; }
  # Make sure it's really a .deb (not an HTML error page)
  dpkg-deb --info "$tmpd/$(basename "$url")" >/dev/null 2>&1 \
    || { rm -rf "$tmpd"; warn "Downloaded file isn't a valid .deb - skipping $repo."; return 1; }
  chmod 755 "$tmpd"; chmod 644 "$tmpd"/*.deb   # let apt's _apt user read it
  apt_install "$tmpd/$(basename "$url")" || { rm -rf "$tmpd"; warn "apt couldn't install $repo (dependency problem?)"; return 1; }
  rm -rf "$tmpd"
  ok "Installed $repo"
}

# ---------- samba ----------
ensure_samba() {
  if command -v smbd >/dev/null 2>&1; then ok "Samba is installed"; return; fi
  warn "Samba isn't installed."
  confirm "Install Samba now?" || die "The File Sharing plugin needs Samba. Aborted."
  if (( IS_DIETPI )) && command -v dietpi-software >/dev/null; then
    local id
    id=$(dietpi-software list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
         | grep -m1 -i '| *Samba Server' | grep -o 'ID [0-9]*' | grep -o '[0-9]*' || true)
    if [[ -n $id ]]; then
      info "Installing Samba Server via dietpi-software (ID $id)"
      dietpi-software install "$id"
      command -v smbd >/dev/null && { ok "Samba installed"; return; }
    fi
    warn "dietpi-software route didn't work, falling back to apt"
  fi
  apt_install samba
  ok "Samba installed"
}

setup_samba_registry() {
  [[ -f $SMB_CONF ]] || die "$SMB_CONF not found"
  if grep -Eiq '^[[:space:]]*include[[:space:]]*=[[:space:]]*registry' "$SMB_CONF"; then
    ok "smb.conf already has 'include = registry'"; return
  fi
  grep -Eiq '^[[:space:]]*\[global\]' "$SMB_CONF" || die "No [global] section in $SMB_CONF"

  mkdir -p "$BACKUP_DIR"
  local backup; backup="$BACKUP_DIR/smb.conf.$(date +%Y%m%d-%H%M%S)"
  cp -a "$SMB_CONF" "$backup"

  # Add the line at the END of [global] (just before the next section),
  # so it's read after all other global settings.
  local tmp; tmp=$(mktemp)
  awk -v mark="$MARKER" '
    function emit() { print "\t" mark; print "\tinclude = registry"; done=1 }
    /^[[:space:]]*\[/ {
      if (in_g && !done) emit()
      in_g = ($0 ~ /^[[:space:]]*\[[Gg][Ll][Oo][Bb][Aa][Ll]\]/)
    }
    { print }
    END { if (in_g && !done) emit() }
  ' "$SMB_CONF" >"$tmp"
  cat "$tmp" >"$SMB_CONF"; rm -f "$tmp"

  if testparm -s "$SMB_CONF" >/dev/null 2>&1; then
    systemctl restart smbd 2>/dev/null || true
    ok "Added 'include = registry' to [global] (backup: $backup)"
    ok "Existing shares in smb.conf (e.g. [dietpi]) keep working"
  else
    cat "$backup" >"$SMB_CONF"
    testparm -s "$SMB_CONF" 2>&1 | tail -n 5 | sed 's/^/    /' >&2 || true
    die "smb.conf failed validation after the change - restored the original."
  fi
}

# ---------- cockpit ----------
set_cockpit_port() {
  local dir=/etc/systemd/system/cockpit.socket.d
  if [[ $PORT == 9090 ]]; then
    rm -f "$dir/listen.conf"
  else
    mkdir -p "$dir"
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$PORT" >"$dir/listen.conf"
    ok "Cockpit will listen on port $PORT"
  fi
  systemctl daemon-reload
}

pick_login_user() {
  # Debian blocks root in /etc/cockpit/disallowed-users; suggest a sudo user instead.
  local u
  for u in dietpi $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    if id "$u" >/dev/null 2>&1 && id -nG "$u" | grep -qw sudo; then echo "$u"; return; fi
  done
}

# ---------- flows ----------
do_uninstall() {
  info "Uninstalling Cockpit and 45Drives plugins"
  confirm "Remove Cockpit, cockpit-file-sharing and cockpit-identities?" || die "Aborted."
  local pkgs=() p
  for p in cockpit-file-sharing cockpit-identities cockpit cockpit-ws cockpit-system cockpit-bridge; do
    dpkg -s "$p" >/dev/null 2>&1 && pkgs+=("$p")
  done
  (( ${#pkgs[@]} )) && DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${pkgs[@]}"
  rm -rf /etc/systemd/system/cockpit.socket.d; systemctl daemon-reload
  apt-get autoremove -y -q >/dev/null 2>&1 || true
  ok "Removed: ${pkgs[*]:-nothing to remove}"
  if grep -q "$MARKER" "$SMB_CONF" 2>/dev/null; then
    warn "Left 'include = registry' in $SMB_CONF - shares you made in Cockpit live in Samba's"
    warn "registry and would disappear if you remove it. List them with: net conf list"
  fi
}

do_install() {
  detect_os
  command -v systemctl >/dev/null || die "systemd is required."

  if dpkg -s cockpit-ws >/dev/null 2>&1; then
    ok "Cockpit already installed - will update the plugins"
  elif port_in_use "$PORT"; then
    die "Port $PORT is already in use. Pick another with --port."
  fi

  local login_user; login_user=$(pick_login_user || true)

  echo
  info "Plan:"
  echo "    Cockpit          : from $CODENAME repos, minimal (no NetworkManager/PackageKit)"
  echo "    Cockpit port     : $PORT"
  echo "    File Sharing     : 45Drives cockpit-file-sharing (latest release)"
  echo "    Identities       : $( (( WITH_IDENTITIES )) && echo 'cockpit-identities (latest release)' || echo skipped)"
  echo "    Samba            : $(command -v smbd >/dev/null && echo installed || echo 'will be installed')"
  echo "    smb.conf         : $( (( SAMBA_SETUP )) && echo "add 'include = registry' (backup to $BACKUP_DIR)" || echo 'leave unchanged')"
  echo
  confirm "Proceed?" || die "Aborted."

  ensure_samba

  info "Installing Cockpit"
  apt-get update -q
  apt_install cockpit curl ca-certificates
  ok "Cockpit installed ($(dpkg-query -W -f='${Version}' cockpit-ws))"
  set_cockpit_port

  # Plugin dependencies (listed by 45Drives) - installed explicitly so the
  # minimal Cockpit install still satisfies them.
  apt_install attr findutils iproute2 nfs-kernel-server samba-common-bin >/dev/null
  install_45drives_deb cockpit-file-sharing || warn "File Sharing plugin NOT installed."
  if (( WITH_IDENTITIES )); then
    install_45drives_deb cockpit-identities || warn "Identities plugin NOT installed (use smbpasswd for Samba passwords)."
  fi

  # NFS server comes along as a dependency; don't run it unless you use NFS.
  if systemctl is-enabled --quiet nfs-server 2>/dev/null && [[ ! -s /etc/exports || -z $(grep -v '^\s*#' /etc/exports | tr -d '[:space:]') ]]; then
    systemctl disable --now nfs-server >/dev/null 2>&1 || true
    ok "Disabled idle NFS server (enable later with: systemctl enable --now nfs-server)"
  fi

  (( SAMBA_SETUP )) && setup_samba_registry

  systemctl enable --now cockpit.socket >/dev/null 2>&1
  systemctl restart cockpit.socket
  ok "Cockpit is running"

  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo
  ok "Open: https://${ip:-your-server}:$PORT   (accept the self-signed certificate)"
  if [[ -n $login_user ]]; then
    echo "    Log in as '$login_user' (root login is blocked by default), then click"
    echo "    'Turn on administrative access' at the top."
  else
    warn "No sudo-capable user found. Root login is blocked in /etc/cockpit/disallowed-users;"
    warn "create a user and add it to the 'sudo' group to manage the server from Cockpit."
  fi
  echo "    Samba shares: sidebar -> File Sharing. Tip: in a share's advanced settings add"
  echo "      force user = dietpi"
  echo "      force group = dietpi"
  echo "    so files stay editable from FileBrowser too."
  echo "    Don't use the plugin's 'Import' button - it replaces smb.conf."
}

main() {
  while (( $# )); do
    case "$1" in
      --port)           PORT=${2:?}; shift ;;
      --no-identities)  WITH_IDENTITIES=0 ;;
      --no-samba-setup) SAMBA_SETUP=0 ;;
      --uninstall)      UNINSTALL=1 ;;
      -y|--yes)         ASSUME_YES=1 ;;
      -h|--help)        usage ;;
      *)                die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  [[ $PORT =~ ^[0-9]+$ ]] || die "--port must be a number"
  [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 ...)"
  if (( UNINSTALL )); then do_uninstall; else do_install; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
