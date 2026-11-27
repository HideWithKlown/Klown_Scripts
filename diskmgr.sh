#!/usr/bin/env bash
# =============================================================================
#  diskmgr.sh  -  menu-driven disk manager (parted / LVM / RAID / mount / fstab)
#
#  Sections:  [List] [Parted] [Filesystem] [LVM] [RAID] [Mount] [Usage]
#
#  Design rules
#   * Every question is a numbered list of valid choices (0 = back/cancel).
#     Free typing only happens when you create something NEW (a name, a size).
#   * Devices that are system disks, mounted, in an active RAID/LVM, or swap
#     are never offered for destructive actions (and the reason is shown).
#   * Destructive actions need you to type the device name (or ERASE).
#   * /etc/fstab and mdadm.conf are backed up before every edit; fstab is
#     verified afterwards and can be rolled back automatically.
#   * Everything that changes the system is written to the log file.
#
#  Usage:   sudo ./diskmgr.sh            normal mode
#           sudo ./diskmgr.sh --dry-run  show commands, execute nothing
#           ALLOW_LOOP=1 sudo ./diskmgr.sh   also offer loop devices (for testing)
# =============================================================================

VERSION="1.0"
DRY_RUN=0
ALLOW_LOOP="${ALLOW_LOOP:-0}"
LOGFILE="/var/log/diskmgr.log"
FSTAB="${FSTAB:-/etc/fstab}"
CRUMB="Main Menu"
FSTAB_LAST_BACKUP=""
REAL_FS="ext2 ext3 ext4 xfs btrfs vfat exfat ntfs ntfs3 fuseblk f2fs"

if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
  CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; CYN=""; BLD=""; RST=""
fi

# Globals filled by helper functions
PICK=""; PICKS=(); SIZE_MIB=0; NAME=""
DISK_ITEMS=(); DEV_ITEMS=(); FS_ITEMS=(); SKIPPED=()
PV_ITEMS=(); VG_ITEMS=(); LV_ITEMS=(); MD_ITEMS=()
CUR_VG=""

# =============================================================================
#  Basic helpers
# =============================================================================
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOGFILE" 2>/dev/null || true; }
info() { printf '%s\n' "${CYN}$*${RST}"; }
ok()   { printf '%s\n' "${GRN}OK: $*${RST}"; }
warn() { printf '%s\n' "${YEL}WARNING: $*${RST}"; }
err()  { printf '%s\n' "${RED}ERROR: $*${RST}"; }
die()  { err "$*"; exit 1; }

# Prompt on stdout, read into REPLY; exit cleanly on EOF (Ctrl-D / closed stdin)
ask() {
  printf '%s' "$1"
  if ! read -r REPLY; then
    echo; log "EOF on input - exiting"; exit 0
  fi
}

pause() { printf '\n'; ask "Press Enter to continue... "; }

confirm() {      # y/N question
  ask "$1 [y/N]: "
  [[ $REPLY =~ ^[Yy]([Ee][Ss])?$ ]]
}

confirm_typed() { # destructive: user must type the token exactly
  local token=$1
  echo "${RED}${BLD}This cannot be undone.${RST}"
  ask "Type ${BLD}${token}${RST} to continue (anything else cancels): "
  [[ $REPLY == "$token" ]]
}

run() {          # log + execute (or just print in dry-run mode)
  log "RUN: $*"
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s %s\n' "$YEL" "$RST" "$*"
    return 0
  fi
  printf '%s$ %s%s\n' "$BLU" "$*" "$RST"
  "$@"
  local rc=$?
  if (( rc != 0 )); then
    err "Command failed with exit code $rc."
    log "FAILED($rc): $*"
  fi
  return $rc
}

show() {         # read-only command: always executed, even in dry-run
  printf '%s$ %s%s\n' "$BLU" "$*" "$RST"
  "$@"
}

fmt_mib() {
  awk -v m="$1" 'BEGIN{
    if (m >= 1048576) printf "%.1f TiB", m/1048576;
    else if (m >= 1024) printf "%.1f GiB", m/1024;
    else printf "%d MiB", m }'
}

pkg_for() {
  case $1 in
    parted|partprobe) echo parted ;;
    mdadm) echo mdadm ;;
    pvcreate|vgcreate|lvcreate|pvs|vgs|lvs|lvextend|lvremove|vgremove|pvremove|vgextend|vgreduce) echo lvm2 ;;
    mkfs.xfs|xfs_repair|xfs_growfs) echo xfsprogs ;;
    mkfs.btrfs|btrfs) echo btrfs-progs ;;
    mkfs.vfat|fsck.vfat) echo dosfstools ;;
    e2fsck|mkfs.ext4|resize2fs) echo e2fsprogs ;;
    lsblk|wipefs|findmnt|blkid|mount|umount) echo util-linux ;;
    *) echo "$1" ;;
  esac
}

need() {         # need cmd1 cmd2 ... ; prints an install hint when missing
  local c missing=() pkgs=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c"); pkgs+=("$(pkg_for "$c")")
    fi
  done
  (( ${#missing[@]} == 0 )) && return 0
  err "Missing command(s): ${missing[*]}"
  local list; list=$(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')
  if   command -v apt-get >/dev/null 2>&1; then info "Install with:  apt install $list"
  elif command -v dnf     >/dev/null 2>&1; then info "Install with:  dnf install $list"
  elif command -v zypper  >/dev/null 2>&1; then info "Install with:  zypper install $list"
  else info "Install the package(s): $list"; fi
  return 1
}

append_line() {  # append_line FILE LINE   (honours dry-run)
  local f=$1 line=$2
  log "APPEND to $f: $line"
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s append to %s: %s\n' "$YEL" "$RST" "$f" "$line"
    return 0
  fi
  printf '%s\n' "$line" >>"$f" || { err "Could not write to $f"; return 1; }
}

# =============================================================================
#  Menus and pickers
# =============================================================================
banner() {
  echo "${BLD}${CYN}==================== Disk Manager v${VERSION} ====================${RST}"
  if (( DRY_RUN )); then echo "${YEL}  DRY-RUN MODE: commands are shown but NOT executed${RST}"; fi
  echo "  $CRUMB"
  echo
}

# run_menu "Name" "Label|function" ...
# An action returning 9 means "user cancelled" (no pause before redraw).
run_menu() {
  local name=$1; shift
  local items=("$@") i idx rc saved=$CRUMB
  local n=${#items[@]}
  [[ $name != "Main Menu" ]] && CRUMB="$CRUMB > [$name]"
  while true; do
    [[ -t 1 ]] && clear
    banner
    echo "${BLD}[${name}]${RST}"
    echo
    for ((i = 0; i < n; i++)); do
      printf '   %d) %s\n' $((i + 1)) "${items[i]%%|*}"
    done
    echo
    if [[ $name == "Main Menu" ]]; then echo "   0) Exit"; else echo "   0) Back to main menu"; fi
    ask "Select [0-$n]: "
    if [[ $REPLY == 0 ]]; then
      break
    elif [[ $REPLY =~ ^[0-9]+$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= n )); then
      idx=$((10#$REPLY - 1))
      echo
      "${items[idx]#*|}"; rc=$?
      (( rc == 9 )) || pause
    else
      warn "Invalid choice: '$REPLY'"; sleep 1
    fi
  done
  CRUMB=$saved
  return 9      # returning from a submenu: no "press Enter" in the parent menu
}

# pick_one "Title" "value|label" ...   -> PICK
# returns 0 = chosen, 1 = user chose Back, 2 = nothing to choose from
pick_one() {
  local title=$1; shift
  local items=("$@") i
  local n=${#items[@]}
  PICK=""
  if (( n == 0 )); then warn "Nothing to choose from."; return 2; fi
  while true; do
    echo; echo "${BLD}${title}${RST}"
    for ((i = 0; i < n; i++)); do
      printf '  %2d) %s\n' $((i + 1)) "${items[i]#*|}"
    done
    printf '   0) Back / cancel\n'
    ask "Choose [0-$n]: "
    [[ $REPLY == 0 ]] && return 1
    if [[ $REPLY =~ ^[0-9]+$ ]] && (( 10#$REPLY >= 1 && 10#$REPLY <= n )); then
      i=$((10#$REPLY - 1))
      PICK=${items[i]%%|*}
      return 0
    fi
    warn "Invalid choice '$REPLY' - enter a number from the list."
  done
}

# pick_many "Title" MIN "value|label" ...   -> PICKS (array)
pick_many() {
  local title=$1 min=$2; shift 2
  local items=("$@") i tok valid sel seen
  local n=${#items[@]}
  PICKS=()
  if (( n == 0 )); then warn "Nothing to choose from."; return 2; fi
  if (( n < min )); then warn "At least $min item(s) are needed but only $n are available."; return 2; fi
  while true; do
    echo; echo "${BLD}${title}${RST}"
    for ((i = 0; i < n; i++)); do
      printf '  %2d) %s\n' $((i + 1)) "${items[i]#*|}"
    done
    printf '   a) Select all\n   0) Back / cancel\n'
    ask "Enter numbers separated by spaces (e.g. 1 3), 'a' = all, 0 = cancel: "
    [[ $REPLY == 0 ]] && return 1
    sel=(); valid=1; seen=" "
    if [[ $REPLY =~ ^[Aa]$ ]]; then
      for ((i = 1; i <= n; i++)); do sel+=("$i"); done
    else
      for tok in ${REPLY//,/ }; do
        if [[ $tok =~ ^[0-9]+$ ]] && (( 10#$tok >= 1 && 10#$tok <= n )) \
           && [[ $seen != *" $((10#$tok)) "* ]]; then
          sel+=("$((10#$tok))"); seen+="$((10#$tok)) "
        else
          warn "Invalid or duplicate entry: '$tok'"; valid=0; break
        fi
      done
    fi
    (( valid )) || continue
    if (( ${#sel[@]} < min )); then warn "Select at least $min item(s)."; continue; fi
    for i in "${sel[@]}"; do PICKS+=("${items[i-1]%%|*}"); done
    return 0
  done
}

# ask_size_mib MAX_MIB -> SIZE_MIB   (new sizes are the only free-typed numbers)
ask_size_mib() {
  local max=$1 num unit mib
  while true; do
    ask "Size (e.g. 500M, 20G, 1T; max $(fmt_mib "$max"); empty = cancel): "
    [[ -z $REPLY ]] && return 1
    if [[ $REPLY =~ ^([0-9]+)([MmGgTt])$ ]]; then
      num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]^^}
      case $unit in
        M) mib=$num ;;
        G) mib=$((num * 1024)) ;;
        T) mib=$((num * 1024 * 1024)) ;;
      esac
      if   (( mib < 8 ));    then warn "Too small (minimum 8M)."
      elif (( mib > max )); then warn "Too large - only $(fmt_mib "$max") available."
      else SIZE_MIB=$mib; return 0; fi
    else
      warn "Invalid size '$REPLY'. Use a whole number followed by M, G or T."
    fi
  done
}

# choose_name "kind" "suggestion" exists_function -> NAME
# Offers the suggestion first; typing a custom name is a second option.
choose_name() {
  local kind=$1 sugg=$2 existsfn=$3 s i=1
  s=$sugg
  while "$existsfn" "$s"; do s="${sugg}${i}"; i=$((i + 1)); done
  pick_one "Name for the new $kind" "$s|$s  (suggested)" "__custom|Type a different name" || return 1
  if [[ $PICK == "__custom" ]]; then
    while true; do
      ask "Name (letters, digits, _ - . only; empty = cancel): "
      [[ -z $REPLY ]] && return 1
      if [[ ! $REPLY =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        warn "Invalid name."
      elif "$existsfn" "$REPLY"; then
        warn "'$REPLY' already exists."
      else
        NAME=$REPLY; return 0
      fi
    done
  fi
  NAME=$PICK
}

# =============================================================================
#  Block-device inspection
# =============================================================================
is_system_mp() {
  case $1 in
    /|/boot|/boot/efi|/usr|/var) return 0 ;;
  esac
  return 1
}

is_real_fs() { [[ " $REAL_FS " == *" $1 "* ]]; }

dev_size()   { lsblk -dnro SIZE "$1" 2>/dev/null; }
dev_model()  { lsblk -dno MODEL "$1" 2>/dev/null | sed 's/[[:space:]]*$//'; }
dev_fstype() { lsblk -nr -o FSTYPE "$1" 2>/dev/null | head -n1; }
dev_mount()  { lsblk -nr -o MOUNTPOINT "$1" 2>/dev/null | sed '/^$/d' | head -n1; }
disk_parts() { lsblk -nrp -o NAME,TYPE "$1" 2>/dev/null | awk '$2=="part"{print $1}'; }

all_disks() {
  lsblk -dnpr -o NAME,TYPE,SIZE 2>/dev/null | awk -v al="$ALLOW_LOOP" '
    ($2=="disk" || (al==1 && $2=="loop")) && $3!="0B" && $1 !~ /\/(zram|ram)[0-9]/ {print $1}'
}

# State of a device INCLUDING everything stacked on top of / inside it.
#   system | swap | mounted | raid-active | lvm-active | encrypted |
#   raid-member | lvm-member | free
dev_state() {
  local dev=$1 mp t f
  local -a mps types fss
  mapfile -t mps < <(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | sed '/^$/d')
  for mp in "${mps[@]}"; do
    if is_system_mp "$mp"; then echo system; return; fi
  done
  for mp in "${mps[@]}"; do
    if [[ $mp == "[SWAP]" ]]; then echo swap; return; fi
  done
  if (( ${#mps[@]} > 0 )); then echo mounted; return; fi
  mapfile -t types < <(lsblk -nr -o TYPE "$dev" 2>/dev/null | tail -n +2)
  for t in "${types[@]}"; do
    case $t in
      raid*|linear) echo raid-active; return ;;
      lvm)          echo lvm-active; return ;;
      crypt)        echo encrypted; return ;;
    esac
  done
  mapfile -t fss < <(lsblk -nr -o FSTYPE "$dev" 2>/dev/null)
  for f in "${fss[@]}"; do
    case $f in
      linux_raid_member) echo raid-member; return ;;
      LVM2_member)       echo lvm-member; return ;;
      crypto_LUKS)       echo encrypted; return ;;
    esac
  done
  echo free
}

state_text() {
  case $1 in
    system)      echo "SYSTEM disk - holds the running OS" ;;
    swap)        echo "used as swap" ;;
    mounted)     echo "mounted" ;;
    raid-active) echo "member of an ACTIVE RAID array" ;;
    lvm-active)  echo "in use by ACTIVE LVM volumes" ;;
    encrypted)   echo "encrypted (LUKS/crypt)" ;;
    raid-member) echo "carries a RAID superblock (array not running)" ;;
    lvm-member)  echo "is an LVM physical volume" ;;
    free)        echo "free" ;;
    *)           echo "$1" ;;
  esac
}

dev_label() {
  local d=$1 type size model fs lbl kids st info=()
  type=$(lsblk -dnro TYPE "$d" 2>/dev/null)
  size=$(dev_size "$d"); model=$(dev_model "$d"); fs=$(dev_fstype "$d")
  lbl=$(lsblk -dnro LABEL "$d" 2>/dev/null)
  kids=$(lsblk -nr -o TYPE "$d" 2>/dev/null | tail -n +2 | grep -c '^part$')
  st=$(dev_state "$d")
  [[ -n $model ]] && info+=("$model")
  (( kids > 0 )) && info+=("$kids partition(s)")
  [[ -n $fs  ]] && info+=("fs=$fs")
  [[ -n $lbl ]] && info+=("label=$lbl")
  [[ $st != free ]] && info+=("[$(state_text "$st")]")
  printf '%-18s %7s  %-6s %s' "$d" "$size" "$type" "${info[*]}"
}

show_skipped() {
  (( ${#SKIPPED[@]} )) || return 0
  echo; echo "${YEL}Not offered (in use or protected):${RST}"
  local s
  for s in "${SKIPPED[@]}"; do echo "   - $s"; done
}

# collect_disks table|partition|any  -> DISK_ITEMS, SKIPPED
#   table     : only completely idle disks (new partition table / wipe)
#   partition : any disk except the system disk
collect_disks() {
  local purpose=$1 d st
  DISK_ITEMS=(); SKIPPED=()
  while read -r d; do
    [[ -z $d ]] && continue
    st=$(dev_state "$d")
    case $purpose in
      table)
        if [[ $st != free ]]; then SKIPPED+=("$d: $(state_text "$st")"); continue; fi ;;
      partition)
        if [[ $st == system ]]; then SKIPPED+=("$d: $(state_text "$st")"); continue; fi ;;
    esac
    DISK_ITEMS+=("$d|$(dev_label "$d")")
  done < <(all_disks)
}

# collect_devs pv|raid|mkfs|wipe -> DEV_ITEMS, SKIPPED
# Candidate block devices: unpartitioned disks, partitions and (for pv/mkfs)
# RAID arrays / (for mkfs) logical volumes.
collect_devs() {
  local purpose=$1 d t st fs kids okt note
  DEV_ITEMS=(); SKIPPED=()
  while read -r d t; do
    [[ -z $d ]] && continue
    okt=0
    case $t in
      disk|part) okt=1 ;;
      loop) [[ $ALLOW_LOOP == 1 ]] && okt=1 ;;
      lvm) [[ $purpose == mkfs ]] && okt=1 ;;
      raid*|linear) [[ $purpose == pv || $purpose == mkfs ]] && okt=1 ;;
    esac
    (( okt )) || continue
    [[ $d == /dev/zram* ]] && continue
    [[ $(dev_size "$d") == "0B" ]] && continue
    if [[ $t == disk || $t == loop ]]; then
      kids=$(lsblk -nr -o NAME "$d" 2>/dev/null | tail -n +2 | wc -l)
      (( kids > 0 )) && continue          # its partitions are listed instead
    fi
    st=$(dev_state "$d")
    case $st in
      free) ;;
      raid-member)
        if [[ $purpose != wipe ]]; then
          SKIPPED+=("$d: $(state_text "$st") - wipe it first (Parted > Wipe signatures)")
          continue
        fi ;;
      *) SKIPPED+=("$d: $(state_text "$st")"); continue ;;
    esac
    fs=$(dev_fstype "$d")
    if [[ $fs == swap && $purpose != wipe ]]; then
      SKIPPED+=("$d: swap area"); continue
    fi
    note=""
    [[ -n $fs ]] && note="   <- existing '$fs' data will be ERASED"
    DEV_ITEMS+=("$d|$(dev_label "$d")$note")
  done < <(lsblk -pnr -o NAME,TYPE 2>/dev/null | sort -u)
}

# collect_fs -> FS_ITEMS : unmounted devices that carry a mountable filesystem
collect_fs() {
  local d fs
  FS_ITEMS=()
  while read -r d fs; do
    [[ -z $d || -z $fs ]] && continue
    is_real_fs "$fs" || continue
    [[ $d == /dev/zram* ]] && continue
    [[ -n $(dev_mount "$d") ]] && continue
    FS_ITEMS+=("$d|$(dev_label "$d")")
  done < <(lsblk -pnr -o NAME,FSTYPE 2>/dev/null | sort -u)
}

wipe_sigs() {    # erase old signatures (caller already got confirmation)
  local d=$1
  if [[ -n $(wipefs "$d" 2>/dev/null | tail -n +2) ]]; then
    run wipefs -a "$d"
  fi
}

udev_settle() {
  if command -v udevadm >/dev/null 2>&1; then run udevadm settle; fi
}

daemon_reload() {   # only when systemd is really running
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    run systemctl daemon-reload
  fi
}

settle_disk() {
  run partprobe "$1"
  udev_settle
}

fstab_refs() {   # does fstab mention this device (by UUID / path)?
  local d=$1 uuid
  uuid=$(blkid -s UUID -o value "$d" 2>/dev/null)
  if [[ -n $uuid ]] && grep -v '^[[:space:]]*#' "$FSTAB" 2>/dev/null | grep -q "$uuid"; then return 0; fi
  grep -v '^[[:space:]]*#' "$FSTAB" 2>/dev/null | grep -q "^${d}[[:space:]]"
}

# bail convention used below:  pick_one ... || return $(( $? == 1 ? 9 : 1 ))
#   Back -> 9 (silent return to the menu), empty list -> 1 (message + pause)

# =============================================================================
#  [List]
# =============================================================================
list_lsblk() { show lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT; }

list_status() {
  local d p
  echo "${BLD}Disks and partitions with their current status:${RST}"
  echo
  while read -r d; do
    [[ -z $d ]] && continue
    echo "  $(dev_label "$d")"
    while read -r p; do
      [[ -n $p ]] && echo "      -> $(dev_label "$p")"
    done < <(disk_parts "$d")
  done < <(all_disks)
  echo
  info "Status 'free' means nothing is using the device; anything else is protected from destructive actions."
}

list_blkid() { show blkid; }

list_mounts() {
  show findmnt -t ext2,ext3,ext4,xfs,btrfs,vfat,exfat,ntfs,ntfs3,fuseblk,f2fs \
       -o TARGET,SOURCE,FSTYPE,OPTIONS
}

list_lvm() {
  need pvs vgs lvs || return 1
  echo "${BLD}Physical volumes${RST}"; pvs
  echo; echo "${BLD}Volume groups${RST}"; vgs
  echo; echo "${BLD}Logical volumes${RST}"; lvs
}

list_raid() {
  echo "${BLD}/proc/mdstat${RST}"
  cat /proc/mdstat 2>/dev/null || warn "No md support loaded."
  local a
  for a in $(md_arrays); do
    echo; echo "${BLD}$a${RST}"
    mdadm --detail "$a" 2>/dev/null
  done
}

fstab_show() { show nl -ba "$FSTAB"; }

menu_list() {
  run_menu "List" \
    "Block devices overview (lsblk)|list_lsblk" \
    "Disks and partitions: free / in use|list_status" \
    "UUIDs and labels (blkid)|list_blkid" \
    "Mounted filesystems|list_mounts" \
    "LVM summary (PV / VG / LV)|list_lvm" \
    "RAID summary|list_raid" \
    "Show /etc/fstab|fstab_show"
}

# =============================================================================
#  [Parted]
# =============================================================================
disk_table() {
  local t
  t=$(parted -ms "$1" print 2>/dev/null | sed -n '2p' | cut -d: -f6)
  case $t in gpt|msdos) echo "$t" ;; *) echo none ;; esac
}

parted_show() {
  need parted lsblk || return 1
  collect_disks any
  pick_one "Show the partition table of which disk?" "${DISK_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  show parted -s "$PICK" unit MiB print free
}

do_mklabel() {   # do_mklabel DISK gpt|msdos   (asks for typed confirmation)
  local disk=$1 type=$2
  echo
  warn "A new $type table REPLACES the current partition table of $disk."
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$disk"
  sig_note "$disk"
  confirm_typed "$disk" || { warn "Cancelled."; return 1; }
  wipe_sigs "$disk"
  run parted -s "$disk" mklabel "$type" || return 1
  settle_disk "$disk"
  ok "Created a $type partition table on $disk"
}

sig_note() {
  local fs; fs=$(dev_fstype "$1")
  [[ -n $fs ]] && echo "   $1 currently holds a '$fs' signature - that data will be erased."
  return 0
}

parted_mklabel() {
  need parted wipefs partprobe || return 1
  collect_disks table; show_skipped
  pick_one "Create a new partition table on which disk?" "${DISK_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local disk=$PICK
  pick_one "Partition table type for $disk" \
    "gpt|GPT   (recommended: disks > 2 TB, up to 128 partitions, UEFI)" \
    "msdos|MBR / msdos   (legacy BIOS, max 4 primary partitions, 2 TB limit)" || return 9
  do_mklabel "$disk" "$PICK"
}

parted_mkpart() {
  need parted lsblk partprobe || return 1
  collect_disks partition; show_skipped
  pick_one "Create a partition on which disk?" "${DISK_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local disk=$PICK table
  table=$(disk_table "$disk")

  if [[ $table == none ]]; then
    warn "$disk has no partition table yet."
    pick_one "Create one now?" \
      "gpt|Yes - GPT (recommended)" \
      "msdos|Yes - MBR / msdos" || return 9
    local newtype=$PICK
    do_mklabel "$disk" "$newtype" || return 1
    if (( DRY_RUN )); then
      info "(dry-run) the partition would be created on the new $newtype table next."
      return 0
    fi
    table=$newtype
  fi

  local total np
  total=$(parted -ms "$disk" unit MiB print 2>/dev/null | sed -n '2p' | cut -d: -f2); total=${total%MiB}
  if [[ $table == msdos ]]; then
    np=$(disk_parts "$disk" | wc -l)
    if (( np >= 4 )); then err "MBR allows only 4 primary partitions and $disk already has $np. Use a GPT disk."; return 1; fi
  fi

  # ---- free-space regions to choose from --------------------------------
  local regions=() n s e sz rest s2 e2
  while IFS=: read -r n s e sz rest; do
    s=${s%MiB}; e=${e%MiB}
    s2=$(awk -v x="$s" 'BEGIN{v=int(x); if (v<x) v++; if (v<1) v=1; print v}')
    e2=$(awk -v x="$e" 'BEGIN{print int(x)}')
    (( e2 - s2 >= 8 )) || continue
    regions+=("$s2:$e2:$e|Free space ${s2} MiB -> ${e2} MiB   ($(fmt_mib $((e2 - s2))) available)")
  done < <(parted -ms "$disk" unit MiB print free 2>/dev/null | grep ':free;$')

  echo; show parted -s "$disk" unit MiB print free
  pick_one "Which free space should the partition use?" "${regions[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local rs re rraw avail
  IFS=: read -r rs re rraw <<<"$PICK"
  avail=$((re - rs))

  pick_one "Partition size (available: $(fmt_mib "$avail"))" \
    "all|All of it ($(fmt_mib "$avail"))" \
    "half|Half of it ($(fmt_mib $((avail / 2))))" \
    "quarter|A quarter of it ($(fmt_mib $((avail / 4))))" \
    "custom|Enter a size myself (e.g. 500M, 20G)" || return 9
  local mode=$PICK size
  case $mode in
    all)     size=$avail ;;
    half)    size=$((avail / 2)) ;;
    quarter) size=$((avail / 4)) ;;
    custom)  ask_size_mib "$avail" || return 9; size=$SIZE_MIB ;;
  esac
  if (( size < 8 )); then err "That would be smaller than 8 MiB."; return 1; fi

  local start=$rs endarg="$((rs + size))MiB"
  if [[ $mode == all ]] && awk -v a="$rraw" -v t="$total" 'BEGIN{exit !(a >= t - 2)}'; then
    endarg="100%"
  fi

  pick_one "What will this partition be used for?" \
    "data|Data - a plain filesystem" \
    "lvm|LVM physical volume (sets the 'lvm' flag)" \
    "raid|Software-RAID member (sets the 'raid' flag)" || return 9
  local purpose=$PICK

  echo; echo "${BLD}Summary${RST}"
  echo "   Disk     : $disk ($table)"
  echo "   Position : ${start} MiB -> ${endarg}   ($(fmt_mib "$size"))"
  echo "   Purpose  : $purpose"
  confirm "Create this partition?" || { warn "Cancelled."; return 9; }

  local before after newp pn
  before=$(disk_parts "$disk" | sort)
  if [[ $table == gpt ]]; then
    run parted -s "$disk" mkpart "$purpose" "${start}MiB" "$endarg" || return 1
  else
    run parted -s "$disk" mkpart primary "${start}MiB" "$endarg" || return 1
  fi
  settle_disk "$disk"
  (( DRY_RUN )) && return 0
  after=$(disk_parts "$disk" | sort)
  newp=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n1)
  if [[ -z $newp ]]; then
    warn "Partition created, but its device name could not be detected. Check the [List] section."
    return 0
  fi
  pn=${newp##*[!0-9]}
  case $purpose in
    lvm)  run parted -s "$disk" set "$pn" lvm on ;;
    raid) run parted -s "$disk" set "$pn" raid on ;;
  esac
  ok "Created $newp"
  case $purpose in
    data) if confirm "Create a filesystem on $newp now?"; then mkfs_on "$newp"; fi ;;
    lvm)  info "Next step: [LVM] > Create physical volume" ;;
    raid) info "Next step: [RAID] > Create array" ;;
  esac
}

parted_rmpart() {
  need parted lsblk partprobe || return 1
  collect_disks partition; show_skipped
  pick_one "Delete a partition from which disk?" "${DISK_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local disk=$PICK p st items=()
  SKIPPED=()
  while read -r p; do
    [[ -z $p ]] && continue
    st=$(dev_state "$p")
    if [[ $st == free ]]; then items+=("$p|$(dev_label "$p")"); else SKIPPED+=("$p: $(state_text "$st")"); fi
  done < <(disk_parts "$disk")
  show_skipped
  pick_one "Which partition do you want to delete?" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local part=$PICK pn
  pn=${part##*[!0-9]}
  echo; warn "Deleting $part destroys everything stored on it."
  sig_note "$part"
  if fstab_refs "$part"; then
    warn "$FSTAB still has an entry for $part - remove it in [Mount] > Remove fstab entry."
  fi
  confirm_typed "$part" || { warn "Cancelled."; return 1; }
  run parted -s "$disk" rm "$pn" || return 1
  settle_disk "$disk"
  ok "Deleted $part"
}

parted_wipefs() {
  need wipefs lsblk || return 1
  collect_devs wipe; show_skipped
  pick_one "Erase old filesystem / RAID signatures from which device?" "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local dev=$PICK
  echo; echo "Signatures currently on $dev:"
  wipefs "$dev"
  warn "Erasing signatures makes the data on $dev unrecognisable."
  confirm_typed "$dev" || { warn "Cancelled."; return 1; }
  run wipefs -a "$dev" && ok "Signatures erased from $dev"
}

menu_parted() {
  run_menu "Parted" \
    "Show partition table (with free space)|parted_show" \
    "Create a partition table (GPT / MBR) on a disk|parted_mklabel" \
    "Create a partition|parted_mkpart" \
    "Delete a partition|parted_rmpart" \
    "Wipe old signatures from a device (wipefs)|parted_wipefs"
}

# =============================================================================
#  [Filesystem]
# =============================================================================
mkfs_on() {      # mkfs_on [device]
  local dev=${1:-}
  need lsblk wipefs || return 1
  if [[ -z $dev ]]; then
    collect_devs mkfs; show_skipped
    pick_one "Create a filesystem on which device?" "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
    dev=$PICK
  fi

  local fsitems=()
  command -v mkfs.ext4  >/dev/null 2>&1 && fsitems+=("ext4|ext4   (default for Linux, journaled, can shrink and grow)")
  command -v mkfs.xfs   >/dev/null 2>&1 && fsitems+=("xfs|xfs    (very good for big files and RAID, can grow but not shrink)")
  command -v mkfs.btrfs >/dev/null 2>&1 && fsitems+=("btrfs|btrfs  (snapshots, checksums, built-in RAID)")
  command -v mkfs.vfat  >/dev/null 2>&1 && fsitems+=("vfat|FAT32  (shared with Windows / cameras; no Unix permissions)")
  if (( ${#fsitems[@]} == 0 )); then err "No mkfs tools found."; need mkfs.ext4; return 1; fi

  pick_one "Filesystem type for $dev" "${fsitems[@]}" || return 9
  local fstype=$PICK label=""
  pick_one "Filesystem label" \
    "none|No label" \
    "custom|Set a label (e.g. data, backup)" || return 9
  if [[ $PICK == custom ]]; then
    while true; do
      ask "Label (1-11 chars: letters, digits, _ -; empty = cancel): "
      [[ -z $REPLY ]] && return 9
      if [[ $REPLY =~ ^[A-Za-z0-9_-]{1,11}$ ]]; then label=$REPLY; break; fi
      warn "Invalid label."
    done
  fi

  local cmd=()
  case $fstype in
    ext4)  cmd=(mkfs.ext4 -F);  [[ -n $label ]] && cmd+=(-L "$label") ;;
    xfs)   cmd=(mkfs.xfs -f);   [[ -n $label ]] && cmd+=(-L "$label") ;;
    btrfs) cmd=(mkfs.btrfs -f); [[ -n $label ]] && cmd+=(-L "$label") ;;
    vfat)  cmd=(mkfs.vfat -F 32); [[ -n $label ]] && cmd+=(-n "$label") ;;
  esac
  cmd+=("$dev")

  echo; echo "${BLD}Summary${RST}"
  echo "   Device     : $(dev_label "$dev")"
  echo "   Filesystem : $fstype${label:+, label '$label'}"
  sig_note "$dev"
  if fstab_refs "$dev"; then warn "$FSTAB references $dev; its UUID will change after formatting."; fi
  confirm_typed "$dev" || { warn "Cancelled."; return 1; }
  wipe_sigs "$dev"
  run "${cmd[@]}" || return 1
  udev_settle
  ok "Created $fstype filesystem on $dev"
  (( DRY_RUN )) && return 0
  if confirm "Mount $dev now?"; then mount_dev "$dev"; fi
}

fs_check() {
  need lsblk || return 1
  collect_fs
  pick_one "Check which (unmounted) filesystem?" "${FS_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local dev=$PICK fs; fs=$(dev_fstype "$dev")
  local chk=() fix=()
  case $fs in
    ext2|ext3|ext4) need e2fsck || return 1; chk=(e2fsck -fn "$dev"); fix=(e2fsck -fp "$dev") ;;
    xfs)            need xfs_repair || return 1; chk=(xfs_repair -n "$dev"); fix=(xfs_repair "$dev") ;;
    btrfs)          need btrfs || return 1; chk=(btrfs check --readonly "$dev") ;;
    vfat)           need fsck.vfat || return 1; chk=(fsck.vfat -n "$dev"); fix=(fsck.vfat -a "$dev") ;;
    *) warn "No checker configured for '$fs'."; return 1 ;;
  esac
  info "Read-only check (nothing is modified):"
  show "${chk[@]}"
  local rc=$?
  if (( rc == 0 )); then ok "No problems reported."; return 0; fi
  warn "The checker exited with code $rc (problems found)."
  if (( ${#fix[@]} )); then
    warn "Repairing can lose data - back up first if the data matters."
    if confirm_typed "$dev"; then run "${fix[@]}"; else warn "Not repaired."; fi
  else
    warn "Automatic repair is not offered for $fs. Use its dedicated tools manually."
  fi
}

menu_filesystem() {
  run_menu "Filesystem" \
    "Create a filesystem (mkfs)|mkfs_on" \
    "Check a filesystem (read-only check, optional repair)|fs_check"
}

# =============================================================================
#  [LVM]
# =============================================================================
vg_exists() { vgs "$1" >/dev/null 2>&1; }
lv_exists() { [[ -e /dev/$CUR_VG/$1 ]] || lvs "$CUR_VG/$1" >/dev/null 2>&1; }
vg_free_mib() { vgs --noheadings --units m --nosuffix -o vg_free "$1" 2>/dev/null | awk '{printf "%d", $1}'; }

free_pv_items() {  # PVs that belong to no VG
  PV_ITEMS=()
  local pv vg sz
  while IFS=: read -r pv vg sz; do
    pv=${pv// /}; [[ -z $pv ]] && continue
    [[ -z ${vg// /} ]] || continue
    PV_ITEMS+=("$pv|$pv  (physical volume, ${sz// /}, not in any volume group)")
  done < <(pvs --noheadings --separator : -o pv_name,vg_name,pv_size 2>/dev/null)
}

vg_items() {       # vg_items [empty]  -> VG_ITEMS ('empty' = only VGs without LVs)
  VG_ITEMS=()
  local vg sz free pvc lvc
  while IFS=: read -r vg sz free pvc lvc; do
    vg=${vg// /}; [[ -z $vg ]] && continue
    pvc=${pvc// /}; lvc=${lvc// /}
    if [[ ${1:-} == empty && $lvc != 0 ]]; then continue; fi
    VG_ITEMS+=("$vg|$vg  (size ${sz// /}, free ${free// /}, $pvc PV, $lvc LV)")
  done < <(vgs --noheadings --separator : -o vg_name,vg_size,vg_free,pv_count,lv_count 2>/dev/null)
}

lv_items() {
  LV_ITEMS=()
  local path vg lv sz mp
  while IFS=: read -r path vg lv sz; do
    path=${path// /}; [[ -z $path ]] && continue
    mp=$(dev_mount "$path")
    LV_ITEMS+=("$path|$path  (${sz// /}, ${mp:+mounted on $mp}${mp:-not mounted})")
  done < <(lvs --noheadings --separator : -o lv_path,vg_name,lv_name,lv_size 2>/dev/null)
}

lvm_pvcreate() {
  need pvcreate wipefs lsblk || return 1
  collect_devs pv; show_skipped
  pick_many "Select the device(s) to turn into LVM physical volumes" 1 "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local devs=("${PICKS[@]}") d
  echo; echo "${BLD}Summary${RST}  - physical volumes will be created on:"
  for d in "${devs[@]}"; do echo "   $d"; sig_note "$d"; done
  confirm_typed "ERASE" || { warn "Cancelled."; return 1; }
  for d in "${devs[@]}"; do
    wipe_sigs "$d"
    run pvcreate -y "$d" || return 1
  done
  ok "Physical volume(s) created."
  info "Next step: Create volume group"
}

lvm_vgcreate() {
  need vgcreate pvs || return 1
  free_pv_items
  if (( ${#PV_ITEMS[@]} == 0 )); then
    warn "No free physical volumes. Use 'Create physical volume' first."; return 1
  fi
  pick_many "Select the physical volume(s) for the new volume group" 1 "${PV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local pvs_sel=("${PICKS[@]}")
  choose_name "volume group" "vg_data" vg_exists || return 9
  local vg=$NAME
  echo; echo "   New volume group '$vg' from: ${pvs_sel[*]}"
  confirm "Create it?" || { warn "Cancelled."; return 9; }
  run vgcreate "$vg" "${pvs_sel[@]}" && ok "Volume group $vg created."
  info "Next step: Create logical volume"
}

lvm_vgextend() {
  need vgextend vgs pvs || return 1
  vg_items
  pick_one "Extend which volume group?" "${VG_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local vg=$PICK
  free_pv_items
  if (( ${#PV_ITEMS[@]} == 0 )); then
    warn "No free physical volumes. Use 'Create physical volume' first."; return 1
  fi
  pick_many "Select the physical volume(s) to add to $vg" 1 "${PV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  confirm "Add ${PICKS[*]} to $vg?" || { warn "Cancelled."; return 9; }
  run vgextend "$vg" "${PICKS[@]}" && ok "$vg extended."
}

lvm_lvcreate() {
  need lvcreate vgs || return 1
  vg_items
  pick_one "Create the logical volume in which volume group?" "${VG_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local vg=$PICK free
  free=$(vg_free_mib "$vg")
  if (( free < 8 )); then err "$vg has no free space. Extend it with another physical volume."; return 1; fi

  pick_one "Size of the new logical volume (free in $vg: $(fmt_mib "$free"))" \
    "100%FREE|All free space ($(fmt_mib "$free"))" \
    "50%FREE|Half of the free space ($(fmt_mib $((free / 2))))" \
    "25%FREE|A quarter of the free space ($(fmt_mib $((free / 4))))" \
    "custom|Enter a size myself (e.g. 5G, 500M)" || return 9
  local szmode=$PICK szarg=()
  if [[ $szmode == custom ]]; then
    ask_size_mib "$free" || return 9
    szarg=(-L "${SIZE_MIB}M")
  else
    szarg=(-l "$szmode")
  fi

  CUR_VG=$vg
  choose_name "logical volume" "lv_data" lv_exists || return 9
  local lv=$NAME
  echo; echo "   New logical volume: /dev/$vg/$lv   (${szarg[*]})"
  confirm "Create it?" || { warn "Cancelled."; return 9; }
  run lvcreate -y "${szarg[@]}" -n "$lv" "$vg" || return 1
  ok "Created /dev/$vg/$lv"
  (( DRY_RUN )) && return 0
  if confirm "Create a filesystem on /dev/$vg/$lv now?"; then mkfs_on "/dev/$vg/$lv"; fi
}

lvm_lvextend() {
  need lvextend lvs vgs || return 1
  lv_items
  pick_one "Extend which logical volume?" "${LV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local lvp=$PICK vg free
  vg=$(lvs --noheadings -o vg_name "$lvp" 2>/dev/null | tr -d ' ')
  free=$(vg_free_mib "$vg")
  if (( free < 8 )); then err "Volume group $vg has no free space left."; return 1; fi
  pick_one "Grow $lvp by (free in $vg: $(fmt_mib "$free"))" \
    "+100%FREE|All free space ($(fmt_mib "$free"))" \
    "+50%FREE|Half of the free space ($(fmt_mib $((free / 2))))" \
    "+25%FREE|A quarter of the free space ($(fmt_mib $((free / 4))))" \
    "custom|Enter an amount myself (e.g. 5G)" || return 9
  local mode=$PICK arg=()
  if [[ $mode == custom ]]; then
    ask_size_mib "$free" || return 9
    arg=(-L "+${SIZE_MIB}M")
  else
    arg=(-l "$mode")
  fi
  info "The filesystem is grown together with the volume (lvextend -r)."
  confirm "Extend $lvp (${arg[*]})?" || { warn "Cancelled."; return 9; }
  run lvextend -r "${arg[@]}" "$lvp" && ok "$lvp extended."
}

lvm_lvremove() {
  need lvremove lvs || return 1
  lv_items
  pick_one "Remove which logical volume?" "${LV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local lvp=$PICK mp
  mp=$(dev_mount "$lvp")
  if [[ -n $mp ]]; then err "$lvp is mounted on $mp. Unmount it first ([Mount] > Unmount)."; return 1; fi
  warn "Removing $lvp destroys all data on it."
  if fstab_refs "$lvp" || grep -q "${lvp#/dev/}" "$FSTAB" 2>/dev/null; then
    warn "$FSTAB mentions this volume - remove that entry afterwards."
  fi
  confirm_typed "$lvp" || { warn "Cancelled."; return 1; }
  run lvremove -y "$lvp" && ok "$lvp removed."
}

lvm_vgreduce() {
  need vgreduce pvs || return 1
  vg_items
  pick_one "Remove a physical volume from which volume group?" "${VG_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local vg=$PICK pv fvg used items=() cnt=0
  SKIPPED=()
  while IFS=: read -r pv fvg used; do
    pv=${pv// /}; fvg=${fvg// /}; used=${used// /}
    [[ $fvg == "$vg" ]] || continue
    cnt=$((cnt + 1))
    if [[ $used =~ ^0(\.0+)?[a-zA-Z]*$ ]]; then items+=("$pv|$pv  (unused)")
    else SKIPPED+=("$pv: still holds data ($used) - move it with 'pvmove $pv' first"); fi
  done < <(pvs --noheadings --separator : -o pv_name,vg_name,pv_used 2>/dev/null)
  if (( cnt < 2 )); then err "$vg has only one physical volume. Remove the whole group instead."; return 1; fi
  show_skipped
  pick_one "Which physical volume should leave $vg?" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  confirm "Remove $PICK from $vg?" || { warn "Cancelled."; return 9; }
  run vgreduce "$vg" "$PICK" && ok "$PICK removed from $vg."
}

lvm_vgremove() {
  need vgremove vgs || return 1
  vg_items empty
  if (( ${#VG_ITEMS[@]} == 0 )); then warn "No volume group without logical volumes (remove the LVs first)."; return 1; fi
  pick_one "Remove which (empty) volume group?" "${VG_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  confirm_typed "$PICK" || { warn "Cancelled."; return 1; }
  run vgremove -y "$PICK" && ok "Volume group removed."
}

lvm_pvremove() {
  need pvremove pvs || return 1
  free_pv_items
  pick_one "Remove the LVM label from which physical volume?" "${PV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  confirm "Remove the LVM label from $PICK?" || { warn "Cancelled."; return 9; }
  run pvremove -y "$PICK" && ok "$PICK is no longer a physical volume."
}

menu_lvm() {
  run_menu "LVM" \
    "Show PV / VG / LV|list_lvm" \
    "Create physical volume (PV)|lvm_pvcreate" \
    "Create volume group (VG)|lvm_vgcreate" \
    "Extend volume group (add PV)|lvm_vgextend" \
    "Create logical volume (LV)|lvm_lvcreate" \
    "Extend logical volume (and its filesystem)|lvm_lvextend" \
    "Remove logical volume|lvm_lvremove" \
    "Remove a PV from a volume group|lvm_vgreduce" \
    "Remove empty volume group|lvm_vgremove" \
    "Remove PV label|lvm_pvremove"
}

# =============================================================================
#  [RAID]
# =============================================================================
md_arrays() { awk '/^md[0-9]+/ {print "/dev/"$1}' /proc/mdstat 2>/dev/null; }

md_conf_path() { if [[ -d /etc/mdadm ]]; then echo /etc/mdadm/mdadm.conf; else echo /etc/mdadm.conf; fi; }

md_members() {
  local md d
  md=$(basename "$(readlink -f "$1")")
  for d in /sys/block/"$md"/md/dev-*; do
    [[ -e $d ]] && echo "/dev/${d##*/dev-}"
  done
}

md_items() {
  MD_ITEMS=()
  local a st
  for a in $(md_arrays); do
    st=$(mdadm --detail "$a" 2>/dev/null | awk -F' : ' '/State :/{print $2; exit}')
    MD_ITEMS+=("$a|$(dev_label "$a")   state: ${st:-unknown}")
  done
}

raid_status() {
  need mdadm || return 1
  list_raid
}

raid_create() {
  need mdadm wipefs lsblk || return 1
  collect_devs raid; show_skipped
  pick_many "Select the devices that will form the array (disks or partitions)" 2 "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local devs=("${PICKS[@]}") n=${#PICKS[@]}

  local levels=()
  levels+=("1|RAID 1  (mirror)  - survives 1 disk failure; usable = smallest disk")
  (( n >= 3 )) && levels+=("5|RAID 5  (parity)  - survives 1 disk failure; usable = (n-1) disks")
  (( n >= 4 )) && levels+=("6|RAID 6  (double parity) - survives 2 disk failures; usable = (n-2) disks")
  (( n >= 4 )) && levels+=("10|RAID 10 (mirror + stripe) - fast, survives 1 failure per mirror pair; usable = n/2")
  levels+=("0|RAID 0  (stripe)  - fastest, NO redundancy: one failed disk loses everything")
  pick_one "RAID level for these $n devices" "${levels[@]}" || return 9
  local level=$PICK minn
  case $level in 0|1) minn=2 ;; 5) minn=3 ;; 6|10) minn=4 ;; esac

  local spare=0 spare_dev=""
  if [[ $level != 0 ]] && (( n > minn )); then
    pick_one "Hot spare (takes over automatically when a disk fails)" \
      "0|No hot spare - use all $n devices as active members" \
      "1|Use the last selected device (${devs[n-1]}) as a hot spare" || return 9
    if [[ $PICK == 1 ]]; then spare=1; spare_dev=${devs[n-1]}; fi
  fi
  local active=$((n - spare)) active_devs=("${devs[@]:0:$((n - spare))}")

  MD_ITEMS=()
  local k=0 name
  while (( ${#MD_ITEMS[@]} < 3 && k < 128 )); do
    name="/dev/md$k"
    if [[ ! -e $name ]] && ! grep -q "^md$k " /proc/mdstat 2>/dev/null; then MD_ITEMS+=("$name|$name"); fi
    k=$((k + 1))
  done
  pick_one "Name of the new array" "${MD_ITEMS[@]}" || return 9
  local md=$PICK

  echo; echo "${BLD}Summary${RST}"
  echo "   Array        : $md  (RAID $level)"
  echo "   Active       : ${active_devs[*]}"
  (( spare )) && echo "   Hot spare    : $spare_dev"
  local d
  for d in "${devs[@]}"; do sig_note "$d"; done
  warn "All data on the devices above will be erased."
  confirm_typed "ERASE" || { warn "Cancelled."; return 1; }

  for d in "${devs[@]}"; do wipe_sigs "$d"; done
  local cmd=(mdadm --create "$md" --level="$level" --raid-devices="$active" --run)
  (( spare )) && cmd+=(--spare-devices=1)
  cmd+=("${active_devs[@]}")
  (( spare )) && cmd+=("$spare_dev")
  run "${cmd[@]}" || return 1
  (( DRY_RUN )) && return 0
  sleep 1
  ok "Array $md created (it may still be syncing in the background)."
  show cat /proc/mdstat
  if confirm "Save the array to $(md_conf_path) so it assembles at boot?"; then raid_save_conf; fi
  if confirm "Create a filesystem on $md now?"; then mkfs_on "$md"; fi
}

raid_save_conf() {
  need mdadm || return 1
  local conf scan line uuid missing=()
  conf=$(md_conf_path)
  scan=$(mdadm --detail --scan 2>/dev/null)
  if [[ -z $scan ]]; then warn "No active arrays found."; return 1; fi
  while read -r line; do
    [[ -z $line ]] && continue
    uuid=$(sed -n 's/.*UUID=\([^ ]*\).*/\1/p' <<<"$line")
    if [[ -n $uuid ]] && grep -qs "$uuid" "$conf"; then continue; fi
    missing+=("$line")
  done <<<"$scan"
  if (( ${#missing[@]} == 0 )); then ok "$conf already lists every active array."; return 0; fi
  echo "These lines will be appended to $conf:"
  printf '   %s\n' "${missing[@]}"
  confirm "Append them?" || { warn "Cancelled."; return 9; }
  if [[ -f $conf ]]; then
    if (( DRY_RUN )); then info "[dry-run] would back up $conf"; else cp -a "$conf" "${conf}.diskmgr.$(date +%Y%m%d_%H%M%S)" && ok "Backed up $conf"; fi
  else
    run mkdir -p "$(dirname "$conf")"
  fi
  for line in "${missing[@]}"; do append_line "$conf" "$line" || return 1; done
  ok "RAID configuration saved."
  if command -v update-initramfs >/dev/null 2>&1; then
    if confirm "Update the initramfs now (recommended so the arrays assemble early at boot)?"; then
      run update-initramfs -u
    fi
  elif command -v dracut >/dev/null 2>&1; then
    info "On this distribution rebuild the initramfs with:  dracut -f"
  fi
}

raid_add() {
  need mdadm lsblk wipefs || return 1
  md_items
  pick_one "Add a device to which array?" "${MD_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local md=$PICK
  collect_devs raid; show_skipped
  pick_one "Which device should be added to $md?" "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local dev=$PICK
  echo; echo "   $dev will be added to $md (as a replacement or hot spare)."
  sig_note "$dev"
  confirm_typed "ERASE" || { warn "Cancelled."; return 1; }
  wipe_sigs "$dev"
  run mdadm "$md" --add "$dev" && ok "$dev added to $md."
}

raid_fail_remove() {
  need mdadm || return 1
  md_items
  pick_one "Remove a device from which array?" "${MD_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local md=$PICK m items=()
  while read -r m; do [[ -n $m ]] && items+=("$m|$m"); done < <(md_members "$md")
  pick_one "Which member of $md should be marked failed and removed?" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local dev=$PICK
  warn "The array becomes DEGRADED (or fails) without $dev."
  confirm_typed "$dev" || { warn "Cancelled."; return 1; }
  run mdadm "$md" --fail "$dev" && run mdadm "$md" --remove "$dev" && ok "$dev removed from $md."
}

raid_stop_remove() {
  need mdadm || return 1
  md_items
  pick_one "Stop and delete which array?" "${MD_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local md=$PICK st
  st=$(dev_state "$md")
  case $st in
    free|raid-member|lvm-member) ;;
    *) err "$md cannot be removed now: $(state_text "$st"). Unmount / remove what uses it first."; return 1 ;;
  esac
  if [[ $st == lvm-member ]]; then
    warn "$md is an LVM physical volume - remove it from its volume group first, or the group will lose a disk."
    confirm "Continue anyway?" || return 9
  fi
  local members=() m uuid conf
  while read -r m; do [[ -n $m ]] && members+=("$m"); done < <(md_members "$md")
  uuid=$(mdadm --detail "$md" 2>/dev/null | awk '/UUID :/{print $3; exit}')
  conf=$(md_conf_path)
  echo; echo "${BLD}This will:${RST}"
  echo "   1) stop $md"
  echo "   2) erase the RAID superblock on: ${members[*]:-(none found)}"
  echo "   3) remove its line from $conf"
  warn "All data on the array is lost."
  if fstab_refs "$md"; then warn "$FSTAB mentions $md - clean it up in [Mount] afterwards."; fi
  confirm_typed "$md" || { warn "Cancelled."; return 1; }
  run mdadm --stop "$md" || return 1
  for m in "${members[@]}"; do run mdadm --zero-superblock "$m"; done
  if [[ -n $uuid && -f $conf ]] && grep -q "$uuid" "$conf"; then
    if (( DRY_RUN )); then info "[dry-run] would remove the $uuid line from $conf"
    else
      cp -a "$conf" "${conf}.diskmgr.$(date +%Y%m%d_%H%M%S)" && sed -i "\|UUID=$uuid|d" "$conf" && ok "Removed from $conf"
    fi
  fi
  ok "$md removed."
  if command -v update-initramfs >/dev/null 2>&1 && confirm "Update the initramfs now?"; then run update-initramfs -u; fi
}

menu_raid() {
  run_menu "RAID" \
    "Show RAID status (mdstat / details)|raid_status" \
    "Create array|raid_create" \
    "Add a device to an array (replace / spare)|raid_add" \
    "Fail and remove a device from an array|raid_fail_remove" \
    "Save array configuration (mdadm.conf, boot-time assembly)|raid_save_conf" \
    "Stop and delete an array|raid_stop_remove"
}

# =============================================================================
#  [Mount]  (mount, unmount, fstab)
# =============================================================================
mounted_user_fs() {   # prints "target<TAB>source<TAB>fstype" for non-system mounts
  local tgt src fst
  while read -r tgt src fst; do
    src=${src%%\[*}
    [[ $src == /dev/* ]] || continue
    is_real_fs "$fst" || continue
    is_system_mp "$tgt" && continue
    printf '%s\t%s\t%s\n' "$tgt" "$src" "$fst"
  done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null)
}

mount_dev() {    # mount_dev [device]
  local dev=${1:-}
  need mount lsblk || return 1
  if [[ -z $dev ]]; then
    collect_fs
    pick_one "Which filesystem do you want to mount?" "${FS_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
    dev=$PICK
  fi

  local lbl sugg items=() d
  lbl=$(lsblk -dnro LABEL "$dev" 2>/dev/null)
  if [[ $lbl =~ ^[A-Za-z0-9_-]+$ ]]; then sugg="/mnt/$lbl"; else sugg="/mnt/$(basename "$dev")"; fi
  if ! mountpoint -q "$sugg" 2>/dev/null; then items+=("$sugg|$sugg   (suggested)"); fi
  while read -r d; do
    [[ -z $d || $d == "$sugg" ]] && continue
    mountpoint -q "$d" 2>/dev/null && continue
    items+=("$d|$d   (existing empty directory)")
  done < <(find /mnt -mindepth 1 -maxdepth 1 -type d -empty 2>/dev/null | sort)
  items+=("__custom|Type a different path")
  pick_one "Mount point for $dev" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local mp=$PICK
  if [[ $mp == "__custom" ]]; then
    while true; do
      ask "Absolute path, no spaces (empty = cancel): "
      [[ -z $REPLY ]] && return 9
      if [[ ! $REPLY =~ ^/[^[:space:]]+$ ]]; then warn "Must be an absolute path without spaces."; continue; fi
      case $REPLY in
        /|/boot|/boot/*|/etc|/usr|/usr/*|/var|/bin|/sbin|/lib|/lib64|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*)
          warn "Refusing to mount on a system directory."; continue ;;
      esac
      if mountpoint -q "$REPLY" 2>/dev/null; then warn "$REPLY is already a mount point."; continue; fi
      mp=$REPLY; break
    done
  fi
  if [[ -d $mp && -n $(ls -A "$mp" 2>/dev/null) ]]; then
    warn "$mp is not empty: its current contents will be hidden while $dev is mounted."
    confirm "Continue?" || return 9
  fi
  [[ -d $mp ]] || run mkdir -p "$mp" || return 1
  run mount "$dev" "$mp" || return 1
  ok "$dev mounted on $mp"
  (( DRY_RUN )) && return 0
  if confirm "Make this mount permanent (add it to $FSTAB)?"; then fstab_add_entry "$dev" "$mp"; fi
}

umount_dev() {
  need umount findmnt || return 1
  local items=() tgt src fst
  while IFS=$'\t' read -r tgt src fst; do
    items+=("$tgt|$tgt   <-  $src   ($fst)")
  done < <(mounted_user_fs)
  pick_one "Unmount which filesystem?" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local mp=$PICK
  confirm "Unmount $mp?" || { warn "Cancelled."; return 9; }
  if ! run umount "$mp"; then
    warn "The filesystem is busy. Programs using it:"
    command -v fuser >/dev/null 2>&1 && fuser -vm "$mp" 2>&1 | head -n 10
    return 1
  fi
  ok "$mp unmounted."
  info "If it is listed in $FSTAB, it will be mounted again at the next boot (remove the entry to prevent that)."
}

fstab_has() {    # fstab_has UUID MOUNTPOINT
  awk -v u="UUID=$1" -v m="$2" '!/^[[:space:]]*#/ && ($1==u || $2==m){f=1} END{exit !f}' "$FSTAB"
}

fstab_backup() {
  local b
  b="${FSTAB}.diskmgr.$(date +%Y%m%d_%H%M%S)"
  FSTAB_LAST_BACKUP=$b
  if (( DRY_RUN )); then info "[dry-run] would back up $FSTAB to $b"; return 0; fi
  cp -a "$FSTAB" "$b" || { err "Could not back up $FSTAB"; return 1; }
  ok "Backup saved: $b"
}

fstab_verify() {
  if findmnt --help 2>&1 | grep -q -- '--verify'; then findmnt --verify; else mount -fav; fi
}

fstab_verify_or_rollback() {
  if (( DRY_RUN )); then info "[dry-run] would verify $FSTAB"; return 0; fi
  info "Verifying $FSTAB ..."
  fstab_verify; local rc=$?
  if (( rc == 0 )); then ok "fstab looks valid."; return 0; fi
  if (( rc == 64 )); then warn "fstab has warnings only (see above)."; return 0; fi
  err "fstab verification reported problems (see above)."
  if [[ -n $FSTAB_LAST_BACKUP ]] && confirm "Restore the previous fstab ($FSTAB_LAST_BACKUP)?"; then
    run cp -a "$FSTAB_LAST_BACKUP" "$FSTAB" && ok "Previous fstab restored."
  else
    warn "fstab left as is - fix it BEFORE you reboot."
  fi
  return 1
}

fstab_add_entry() {   # fstab_add_entry SOURCE MOUNTPOINT
  local src=$1 mp=$2 uuid fst opts pass line
  need blkid || return 1
  uuid=$(blkid -s UUID -o value "$src" 2>/dev/null)
  fst=$(blkid -s TYPE -o value "$src" 2>/dev/null)
  if [[ -z $uuid || -z $fst ]]; then err "Cannot read the UUID / filesystem type of $src."; return 1; fi
  if fstab_has "$uuid" "$mp"; then warn "$FSTAB already has an entry for this filesystem or mount point."; return 1; fi
  pick_one "Mount options for $mp" \
    "defaults,nofail|defaults,nofail   (recommended for extra disks: boot continues if the disk is missing)" \
    "defaults|defaults   (boot stops in emergency mode if the disk is missing)" \
    "defaults,noatime,nofail|defaults,noatime,nofail   (fewer writes; good for SSDs and busy disks)" \
    "ro,nofail|ro,nofail   (read-only)" || return $(( $? == 1 ? 9 : 1 ))
  opts=$PICK
  case $fst in ext2|ext3|ext4) pass=2 ;; *) pass=0 ;; esac
  line="UUID=$uuid $mp $fst $opts 0 $pass"
  echo; echo "New line for $FSTAB:"; echo "   $line"
  confirm "Add it?" || { warn "Cancelled."; return 9; }
  fstab_backup || return 1
  append_line "$FSTAB" "$line" || return 1
  daemon_reload
  fstab_verify_or_rollback
}

fstab_add() {
  need findmnt blkid || return 1
  local items=() tgt src fst uuid
  while IFS=$'\t' read -r tgt src fst; do
    uuid=$(blkid -s UUID -o value "$src" 2>/dev/null)
    fstab_has "$uuid" "$tgt" && continue
    items+=("$tgt|$tgt   <-  $src   ($fst)")
  done < <(mounted_user_fs)
  if (( ${#items[@]} == 0 )); then
    warn "Every mounted data filesystem is already in $FSTAB (or nothing is mounted). Mount one first."
    return 1
  fi
  pick_one "Make which mounted filesystem permanent?" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local mp=$PICK
  src=$(findmnt -rn -o SOURCE "$mp" | head -n1); src=${src%%\[*}
  fstab_add_entry "$src" "$mp"
}

fstab_remove() {
  local items=() n line second
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    read -r _ second _ <<<"$line"
    is_system_mp "$second" && continue
    [[ $second == swap || $second == none ]] && continue
    items+=("$n|line $n:  $line")
  done <"$FSTAB"
  pick_one "Disable which $FSTAB entry? (system entries are hidden)" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local ln=$PICK
  echo "   Line $ln will be commented out (kept in the file, but no longer used)."
  confirm "Continue?" || { warn "Cancelled."; return 9; }
  fstab_backup || return 1
  if (( DRY_RUN )); then
    info "[dry-run] would comment out line $ln of $FSTAB"
  else
    sed -i "${ln}s|^|# disabled by diskmgr $(date +%F): |" "$FSTAB" || return 1
    log "fstab line $ln commented out"
  fi
  daemon_reload
  fstab_verify_or_rollback
}

fstab_verify_menu() { fstab_verify; }

fstab_restore() {
  local items=() f
  while read -r f; do
    [[ -n $f ]] && items+=("$f|$f")
  done < <(ls -1t "${FSTAB}".diskmgr.* 2>/dev/null)
  if (( ${#items[@]} == 0 )); then warn "No fstab backups found."; return 1; fi
  pick_one "Restore which backup? (newest first)" "${items[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local b=$PICK
  echo "   Differences between the backup and the current file:"
  diff "$b" "$FSTAB" | head -n 20
  confirm "Replace $FSTAB with this backup?" || { warn "Cancelled."; return 9; }
  fstab_backup || return 1
  run cp -a "$b" "$FSTAB" && ok "Restored."
  daemon_reload
}

menu_mount() {
  run_menu "Mount" \
    "Mount a filesystem|mount_dev" \
    "Unmount a filesystem|umount_dev" \
    "Make a mounted filesystem permanent (add to fstab)|fstab_add" \
    "Disable an fstab entry|fstab_remove" \
    "Show /etc/fstab|fstab_show" \
    "Verify /etc/fstab|fstab_verify_menu" \
    "Restore an fstab backup|fstab_restore"
}

# =============================================================================
#  [Usage]
# =============================================================================
df_colored() {   # df_colored space|inodes
  local args=(-hT)
  [[ $1 == inodes ]] && args+=(-i)
  df "${args[@]}" -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null |
    awk -v R="$RED" -v Y="$YEL" -v N="$RST" '
      NR==1 {print; next}
      { p=$6; gsub("%","",p);
        if (p+0 >= 90) print R $0 N; else if (p+0 >= 80) print Y $0 N; else print }'
  echo; info "Yellow = 80% or more used, red = 90% or more."
}

usage_space()  { echo "${BLD}Disk space${RST}";  df_colored space; }
usage_inodes() { echo "${BLD}Inodes (number of files)${RST}"; df_colored inodes; }

usage_mount_items() {
  local t
  DEV_ITEMS=()
  while read -r t; do
    [[ -z $t ]] && continue
    DEV_ITEMS+=("$t|$t   ($(df -h --output=size,used,pcent "$t" 2>/dev/null | tail -n1 | awk '{print $1" total, "$2" used, "$3}'))")
  done < <(df --output=target -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
}

usage_bigdirs() {
  usage_mount_items
  pick_one "Which filesystem should be scanned?" "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local mp=$PICK
  info "Largest top-level directories on $mp (this can take a while on big disks):"
  du -xh --max-depth=1 "$mp" 2>/dev/null | sort -rh | head -n 16
}

usage_inodehogs() {
  usage_mount_items
  pick_one "Which filesystem should be scanned?" "${DEV_ITEMS[@]}" || return $(( $? == 1 ? 9 : 1 ))
  local mp=$PICK d
  info "Number of files per top-level directory on $mp (this can take a while):"
  while read -r d; do
    printf '%10d  %s\n' "$(find "$d" -xdev 2>/dev/null | wc -l)" "$d"
  done < <(find "$mp" -xdev -mindepth 1 -maxdepth 1 -type d 2>/dev/null) | sort -rn | head -n 15
}

menu_usage() {
  run_menu "Usage" \
    "Disk space per filesystem (df)|usage_space" \
    "Inode usage per filesystem (df -i)|usage_inodes" \
    "Largest directories on a filesystem|usage_bigdirs" \
    "Directories with the most files (inode hogs)|usage_inodehogs"
}

# =============================================================================
#  Main
# =============================================================================
usage_text() {
  cat <<EOF
diskmgr.sh v$VERSION - menu-driven disk, LVM and RAID manager

  sudo ./diskmgr.sh              start the menu
  sudo ./diskmgr.sh --dry-run    show every command but execute nothing
  ALLOW_LOOP=1 sudo ./diskmgr.sh also offer loop devices (for practising)

Log file: $LOGFILE (falls back to /tmp/diskmgr.log)
EOF
}

main() {
  while (( $# )); do
    case $1 in
      -n|--dry-run) DRY_RUN=1 ;;
      -h|--help)    usage_text; exit 0 ;;
      *)            usage_text; die "Unknown option: $1" ;;
    esac
    shift
  done

  (( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is required."
  if (( EUID != 0 )); then
    if (( DRY_RUN )); then
      warn "Not running as root: some read-only queries may fail."
      sleep 1
    else
      die "Run as root:  sudo $0     (or use --dry-run to look around without root)"
    fi
  fi
  need lsblk || exit 1
  touch "$LOGFILE" 2>/dev/null || LOGFILE=/tmp/diskmgr.log
  log "=== session start (dry-run=$DRY_RUN) ==="
  trap 'echo; echo "Interrupted."; exit 130' INT

  run_menu "Main Menu" \
    "[List]        show disks, partitions, LVM, RAID, mounts|menu_list" \
    "[Parted]      partition tables and partitions|menu_parted" \
    "[Filesystem]  create (mkfs) and check filesystems|menu_filesystem" \
    "[LVM]         physical volumes, volume groups, logical volumes|menu_lvm" \
    "[RAID]        create and manage software RAID (mdadm)|menu_raid" \
    "[Mount]       mount, unmount, fstab|menu_mount" \
    "[Usage]       space, inodes, biggest directories|menu_usage"
  echo "Bye."
  log "=== session end ==="
}

main "$@"
