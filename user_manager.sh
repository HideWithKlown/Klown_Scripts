#!/usr/bin/bash
#
# user_manager.sh - menu driven user and group manager
#
# Usage:
#   sudo ./user_manager.sh                 interactive menu
#   sudo ./user_manager.sh -f users.csv    batch import from a CSV file
#   ./user_manager.sh -n [-f users.csv]    dry run: changing commands are only printed
#   ./user_manager.sh -h                   help
#
# CSV format (header line and lines starting with # are ignored):
#   username,fullname,primary_group,secondary_groups,shell,max_pass_days
#   jdoe,John Doe,developers,sudo;docker,/bin/bash,60
#   (secondary groups are separated with ";", shell and max days can be empty)

# ---------- settings you will probably want to change ----------
DEFAULT_SHELL="/bin/bash"
DEFAULT_MAX_DAYS=90                       # chage -M
MIN_DAYS=1                                # chage -m
WARN_DAYS=7                               # chage -W
LOG_FILE="/var/log/user_manager.log"
BACKUP_DIR="/var/backups/user_manager"
CRED_FILE="./credentials_$(date +%F).txt"
NAME_REGEX='^[a-z_][a-z0-9_-]{0,31}$'
EXTRA_GROUPS=(sudo wheel adm docker)      # system groups always offered in the pick lists
# ----------------------------------------------------------------

DRY_RUN=0
CSV_FILE=""

# where regular (non-system) accounts start, read from login.defs
UID_MIN=$(awk '/^UID_MIN/ {print $2}' /etc/login.defs 2> /dev/null)
GID_MIN=$(awk '/^GID_MIN/ {print $2}' /etc/login.defs 2> /dev/null)
UID_MIN=${UID_MIN:-1000}
GID_MIN=${GID_MIN:-1000}
NOBODY_ID=65534

# ---------- colors (only when output is a terminal) ----------

if [ -t 1 ] && command -v tput > /dev/null 2>&1 && [ "$(tput colors 2> /dev/null || echo 0)" -ge 8 ]; then
        RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RESET=$(tput sgr0)
else
        RED=""; GREEN=""; YELLOW=""; RESET=""
fi

ok()   { echo "${GREEN}$*${RESET}"; }
warn() { echo "${YELLOW}WARNING: $*${RESET}"; }
err()  { echo "${RED}ERROR: $*${RESET}" >&2; }

# ---------- small helpers ----------

usage() {
        cat <<EOF
Usage: $0 [-f csv_file] [-n] [-h]
  -f FILE   batch mode: create users from a CSV file
  -n        dry run: only print the commands that would change something
  -h        show this help
Without -f the interactive menu starts.
EOF
}

# write a line to the log file (errors are ignored if the file is not writable)
log() {
        [ "$DRY_RUN" -eq 1 ] && return 0
        { echo "$(date '+%F %T') [${SUDO_USER:-$(whoami)}] $*" >> "$LOG_FILE"; } 2> /dev/null
}

# read a line into the variable named in $1, exit cleanly if input is closed (Ctrl-D)
ask() {
        read -r "$1" || { echo; echo "Input closed, exiting"; exit 0; }
}

confirm() {
        local answer
        echo "$1 (y/n)"
        ask answer
        [ "$answer" = "y" ]
}

# run a command that changes the system: logs it, or only prints it in dry-run mode
do_cmd() {
        local rc
        if [ "$DRY_RUN" -eq 1 ]; then
                echo "  [dry-run] $*"
                return 0
        fi
        "$@"
        rc=$?
        if [ $rc -eq 0 ]; then
                log "OK    $*"
        else
                log "FAIL  (exit $rc) $*"
        fi
        return $rc
}

# "--" stops a typed name like "-u" from being read as an option
user_exists() {
        id -- "$1" &> /dev/null
}

group_exists() {
        getent group -- "$1" > /dev/null
}

valid_name() {
        [[ "$1" =~ $NAME_REGEX ]]
}

shell_ok() {
        [ -n "$1" ] && grep -v '^#' /etc/shells | grep -qxF -- "$1"
}

have() {
        command -v "$1" > /dev/null 2>&1
}

gen_password() {
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14
}

# days from now until a date string, fails if it is not a date ("never" etc.)
days_until() {
        local t
        [ -n "$1" ] || return 1
        t=$(date -d "$1" +%s 2> /dev/null) || return 1
        echo $(( (t - $(date +%s)) / 86400 ))
}

fmt_days() {
        if [ "$1" -lt 0 ]; then
                echo "EXPIRED $(( -$1 )) days ago"
        else
                echo "in $1 days"
        fi
}

# refuse to touch system accounts, root and the user running this script
protected_user() {
        local uid
        uid=$(id -u "$1" 2> /dev/null)
        if [ "$1" = "root" ] || [ "${uid:-0}" -lt "$UID_MIN" ] || [ "${uid:-0}" -ge "$NOBODY_ID" ]; then
                err "$1 is a system account (UID ${uid:-?}), refusing"
                return 0
        fi
        if [ "$1" = "${SUDO_USER:-}" ]; then
                err "$1 is the user running this script, refusing"
                return 0
        fi
        return 1
}

regular_users() {
        getent passwd | awk -F: -v min="$UID_MIN" -v max="$NOBODY_ID" '$3 >= min && $3 < max {print $1}'
}

regular_groups() {
        getent group | awk -F: -v min="$GID_MIN" -v max="$NOBODY_ID" '$3 >= min && $3 < max {print $1}'
}

# regular groups plus the system groups listed in EXTRA_GROUPS (if they exist)
pickable_groups() {
        local g
        {
                regular_groups
                for g in "${EXTRA_GROUPS[@]}"; do
                        group_exists "$g" && echo "$g"
                done
        } | awk '!seen[$0]++'
}

# ---------- numbered pick menus (select) ----------

# pick_item <variable> <label> <items...>
# numbered menu, plus "(type a name)" and "(cancel)". Returns 1 if nothing was picked.
pick_item() {
        local var="$1" label="$2" choice
        shift 2
        local items=("$@")
        printf -v "$var" ''
        echo
        if [ ${#items[@]} -eq 0 ]; then
                echo "(no ${label}s in the list)"
        fi
        PS3="Pick a $label by number: "
        select choice in "${items[@]}" "(type a name)" "(cancel)"; do
                case $choice in
                        "(type a name)") echo "Name of a $label"; ask "$var"; break;;
                        "(cancel)") return 1;;
                        "") echo "Invalid choice, try again";;
                        *) printf -v "$var" '%s' "$choice"; break;;
                esac
        done
        [ -n "${!var}" ]
}

pick_user() {
        local list
        mapfile -t list < <(regular_users)
        pick_item username user "${list[@]}"
}

pick_group() {
        local list
        mapfile -t list < <(pickable_groups)
        pick_item groupname group "${list[@]}"
}

# pick a user / group and check that it exists
need_user() {
        pick_user || return 1
        if ! user_exists "$username"; then
                err "User $username does not exist"
                return 1
        fi
}

need_group() {
        pick_group || return 1
        if ! group_exists "$groupname"; then
                err "Group $groupname does not exist"
                return 1
        fi
}

# ---------- 1) Create ----------

create_user() {
        local fullname shell extra g glist missing=0 cmd=()
        echo "Name of a user"; ask username
        if ! valid_name "$username"; then
                err "Invalid name: use lowercase letters, digits, - and _ (max 32), start with a letter or _"
                return
        fi
        if user_exists "$username"; then
                err "User $username already exists"
                return
        fi
        echo "Full name (Enter to skip)"; ask fullname
        echo "Shell (Enter for $DEFAULT_SHELL)"; ask shell
        shell="${shell:-$DEFAULT_SHELL}"
        if ! shell_ok "$shell"; then
                warn "$shell is not listed in /etc/shells, using $DEFAULT_SHELL"
                shell="$DEFAULT_SHELL"
        fi
        echo "Extra groups, comma separated (Enter for none)"; ask extra
        extra="${extra// /}"
        if [ -n "$extra" ]; then
                IFS=',' read -ra glist <<< "$extra"
                for g in "${glist[@]}"; do
                        if ! group_exists "$g"; then
                                err "Group $g does not exist"
                                missing=1
                        fi
                done
                [ $missing -eq 0 ] || return
                extra=$(IFS=,; echo "${glist[*]}")
        fi

        cmd=(useradd -m -s "$shell")
        [ -n "$fullname" ] && cmd+=(-c "$fullname")
        [ -n "$extra" ] && cmd+=(-G "$extra")
        cmd+=("$username")

        if do_cmd "${cmd[@]}"; then
                ok "User $username created"
                echo "Set a password for $username"
                if do_cmd passwd "$username"; then
                        ok "Password is set"
                else
                        warn "Password not set, the account stays locked until you set one"
                fi
        else
                err "useradd failed for $username"
        fi
}

create_system_user() {
        local comment nologin cmd=()
        echo "Name of the system user"; ask username
        if ! valid_name "$username"; then
                err "Invalid name"
                return
        fi
        if user_exists "$username"; then
                err "User $username already exists"
                return
        fi
        echo "Description (Enter to skip)"; ask comment
        nologin=$(command -v nologin || echo /usr/sbin/nologin)
        cmd=(useradd -r -s "$nologin")
        [ -n "$comment" ] && cmd+=(-c "$comment")
        cmd+=("$username")
        if do_cmd "${cmd[@]}"; then
                ok "System user $username created (no home directory, no login shell)"
        else
                err "useradd failed for $username"
        fi
}

create_group() {
        echo "Name of a group"; ask groupname
        if ! valid_name "$groupname"; then
                err "Invalid name"
                return
        fi
        if group_exists "$groupname"; then
                err "Group $groupname already exists"
                return
        fi
        if do_cmd groupadd "$groupname"; then
                ok "Group $groupname created"
                if confirm "Set a group password?"; then
                        if do_cmd gpasswd "$groupname"; then
                                ok "Password is set"
                        else
                                warn "Password not set"
                        fi
                fi
        else
                err "groupadd failed for $groupname"
        fi
}

create_system_group() {
        echo "Name of the system group"; ask groupname
        if ! valid_name "$groupname"; then
                err "Invalid name"
                return
        fi
        if group_exists "$groupname"; then
                err "Group $groupname already exists"
                return
        fi
        if do_cmd groupadd -r "$groupname"; then
                ok "System group $groupname created"
        else
                err "groupadd failed for $groupname"
        fi
}

list_create() {
        while true; do
                echo
                echo "[Create] Welcome to Create section"
                echo "[Create] What do you want to do?"
                echo "[Create] 1) Create a user"
                echo "[Create] 2) Create a system user (no home, no login)"
                echo "[Create] 3) Create a group"
                echo "[Create] 4) Create a system group"
                echo "[Create] 0) Go back a section"
                ask state
                case $state in
                        1) create_user;;
                        2) create_system_user;;
                        3) create_group;;
                        4) create_system_group;;
                        0) return;;
                        *) err "Invalid input";;
                esac
        done
}

# ---------- 2) Modify / Add ----------

add_to_group() {
        need_user || return
        need_group || return
        if do_cmd usermod -aG "$groupname" "$username"; then
                ok "$username added to $groupname"
        else
                err "Could not add $username to $groupname"
        fi
}

change_user_password() {
        need_user || return
        if do_cmd passwd "$username"; then
                ok "Password is set"
        else
                err "Password was not changed"
        fi
}

change_group_password() {
        need_group || return
        if do_cmd gpasswd "$groupname"; then
                ok "Password is set"
        else
                err "Password was not changed"
        fi
}

set_max_age() {
        local days
        need_user || return
        echo "Max days before password must change"; ask days
        if [[ ! "$days" =~ ^[0-9]+$ ]] || [ "$days" -lt 1 ] || [ "$days" -gt 99999 ]; then
                err "Days must be a number from 1 to 99999"
                return
        fi
        if do_cmd chage -M "$days" "$username"; then
                ok "Max age set to $days days"
                if [ "$DRY_RUN" -eq 0 ]; then chage -l "$username"; fi
        else
                err "chage failed"
        fi
}

force_pw_change() {
        need_user || return
        if do_cmd chage -d 0 "$username"; then
                ok "$username must change password at next login"
        else
                err "chage failed"
        fi
}

lock_user() {
        need_user || return
        protected_user "$username" && return
        if do_cmd usermod -L "$username"; then
                ok "$username is locked"
                echo "Note: this locks the password only. SSH key logins still work."
                echo "For a full lock also set the account expiry to a past date (Modify menu)."
        else
                err "usermod failed"
        fi
}

unlock_user() {
        need_user || return
        if do_cmd usermod -U "$username"; then
                ok "$username is unlocked"
        else
                err "usermod failed"
        fi
}

set_expiry() {
        local d
        need_user || return
        protected_user "$username" && return
        echo "Expiry date (YYYY-MM-DD, or +30 days, or 'never')"; ask d
        if [ -z "$d" ]; then
                # date -d "" means "today", which would lock the account right away
                err "No date given"
                return
        fi
        if [ "$d" = "never" ]; then
                d="-1"
        else
                d=$(date -d "$d" +%F 2> /dev/null) || { err "Not a valid date"; return; }
        fi
        if do_cmd chage -E "$d" "$username"; then
                ok "Account expiry for $username set to $d (-1 = never)"
        else
                err "chage failed"
        fi
}

change_shell() {
        local shell
        need_user || return
        echo "Valid shells (/etc/shells):"
        grep -v '^#' /etc/shells | sed 's/^/  /'
        echo "New shell"; ask shell
        if ! shell_ok "$shell"; then
                err "$shell is not listed in /etc/shells"
                return
        fi
        if do_cmd usermod -s "$shell" "$username"; then
                ok "Shell of $username is now $shell"
        else
                err "usermod failed"
        fi
}

change_fullname() {
        local fullname
        need_user || return
        echo "New full name (empty clears it)"; ask fullname
        if do_cmd usermod -c "$fullname" "$username"; then
                ok "Full name of $username changed"
        else
                err "usermod failed"
        fi
}

change_primary_group() {
        need_user || return
        need_group || return
        if do_cmd usermod -g "$groupname" "$username"; then
                ok "Primary group of $username is now $groupname"
        else
                err "usermod failed"
        fi
}

change_uid() {
        local newuid
        need_user || return
        protected_user "$username" && return
        echo "New UID (must be $UID_MIN or higher)"; ask newuid
        if [[ ! "$newuid" =~ ^[0-9]+$ ]] || [ "$newuid" -lt "$UID_MIN" ] || [ "$newuid" -ge "$NOBODY_ID" ]; then
                err "UID must be a number from $UID_MIN to $((NOBODY_ID - 1))"
                return
        fi
        if getent passwd "$newuid" > /dev/null; then
                err "UID $newuid is already used by $(getent passwd "$newuid" | cut -d: -f1)"
                return
        fi
        warn "usermod fixes ownership of the home directory and mail spool only."
        echo "Files owned elsewhere keep the old UID (find / -xdev -uid OLD finds them)."
        confirm "Change UID of $username to $newuid?" || { echo "Cancelled"; return; }
        if do_cmd usermod -u "$newuid" "$username"; then
                ok "UID of $username is now $newuid"
        else
                err "usermod failed (is the user logged in or running processes?)"
        fi
}

rename_user() {
        local newname rename_home=0 old_home new_home
        need_user || return
        protected_user "$username" && return
        echo "New name for $username"; ask newname
        if ! valid_name "$newname"; then
                err "Invalid name"
                return
        fi
        if user_exists "$newname"; then
                err "User $newname already exists"
                return
        fi
        # the new home sits next to the old one (usually /home)
        old_home=$(getent passwd "$username" | cut -d: -f6)
        new_home="$(dirname "$old_home")/$newname"
        if [ -z "$old_home" ] || [ "$old_home" = "/" ] || [ ! -d "$old_home" ]; then
                echo "(home directory '$old_home' is not a normal directory, it will not be renamed)"
        elif [ -e "$new_home" ]; then
                warn "$new_home already exists, the home directory will not be renamed"
        else
                confirm "Also rename the home directory to $new_home?" && rename_home=1
        fi
        if do_cmd usermod -l "$newname" "$username"; then
                ok "User renamed: $username -> $newname"
                if [ $rename_home -eq 1 ]; then
                        if do_cmd usermod -d "$new_home" -m "$newname"; then
                                ok "Home directory moved to $new_home"
                        else
                                err "Could not move the home directory"
                        fi
                fi
                echo "Note: the group name is not changed (groupmod -n renames a group)."
        else
                err "usermod failed (is the user logged in or running processes?)"
        fi
}

add_to_sudo() {
        local admin rule
        need_user || return
        if group_exists sudo; then
                admin="sudo"
        elif group_exists wheel; then
                admin="wheel"
        else
                err "No sudo or wheel group on this system"
                return
        fi
        warn "This gives $username full root rights through sudo."
        echo "Members of $admin can only use sudo if sudoers has a rule for %$admin."
        echo "Edit sudoers ONLY with visudo, never directly."
        rule=$(grep -rhE "^%${admin}[[:space:]]" /etc/sudoers /etc/sudoers.d 2> /dev/null)
        if [ -n "$rule" ]; then
                echo "Found rule: $rule"
        else
                warn "No rule for %$admin found in sudoers"
        fi
        confirm "Add $username to $admin?" || { echo "Cancelled"; return; }
        if do_cmd usermod -aG "$admin" "$username"; then
                ok "$username added to $admin"
        else
                err "usermod failed"
        fi
}

list_modify() {
        while true; do
                echo
                echo "[Modify] Welcome to Modify / Add section"
                echo "[Modify] What do you want to do?"
                echo "[Modify] 1) Add a user to a group"
                echo "[Modify] 2) Change a user's password"
                echo "[Modify] 3) Change a group's password"
                echo "[Modify] 4) Set password max age for a user"
                echo "[Modify] 5) Force a user to change password at next login"
                echo "[Modify] 6) Lock a user"
                echo "[Modify] 7) Unlock a user"
                echo "[Modify] 8) Set account expiry date"
                echo "[Modify] 9) Change a user's shell"
                echo "[Modify] 10) Change a user's full name"
                echo "[Modify] 11) Change a user's primary group"
                echo "[Modify] 12) Change a user's UID"
                echo "[Modify] 13) Rename a user"
                echo "[Modify] 14) Add a user to sudo"
                echo "[Modify] 0) Go back a section"
                ask state
                case $state in
                        1) add_to_group;;
                        2) change_user_password;;
                        3) change_group_password;;
                        4) set_max_age;;
                        5) force_pw_change;;
                        6) lock_user;;
                        7) unlock_user;;
                        8) set_expiry;;
                        9) change_shell;;
                        10) change_fullname;;
                        11) change_primary_group;;
                        12) change_uid;;
                        13) rename_user;;
                        14) add_to_sudo;;
                        0) return;;
                        *) err "Invalid input";;
                esac
        done
}

# ---------- 3) Delete / Remove ----------

# tar the home directory into BACKUP_DIR (only root can read the result)
backup_home() {
        local user="$1" home="$2" file
        file="$BACKUP_DIR/${user}_$(date +%F_%H%M%S).tar.gz"
        if [ "$DRY_RUN" -eq 0 ]; then
                ( umask 077; mkdir -p "$BACKUP_DIR" ) || return 1
        fi
        if do_cmd tar -czf "$file" -C "$(dirname "$home")" "$(basename "$home")"; then
                [ "$DRY_RUN" -eq 0 ] && chmod 600 "$file"
                ok "Backup saved: $file"
        else
                rm -f "$file"
                return 1
        fi
}

delete_user_with_home() {
        local home others rc
        need_user || return
        protected_user "$username" && return
        home=$(getent passwd "$username" | cut -d: -f6)
        if [ -z "$home" ] || [ "$home" = "/" ]; then
                err "Home directory of $username is '${home:-empty}', refusing to delete it. Use 'keep the home directory' instead."
                return
        fi
        # never remove a home that other accounts share or live inside
        others=$(getent passwd | awk -F: -v h="$home" -v u="$username" '$1 != u && ($6 == h || index($6, h "/") == 1) {printf "%s ", $1}')
        if [ -n "$others" ]; then
                err "$home is shared with, or contains the home of: $others. Refusing. Use 'keep the home directory' instead."
                return
        fi
        warn "This deletes $username AND the home directory $home"
        confirm "Really delete $username?" || { echo "Cancelled"; return; }
        if [ -d "$home" ] && confirm "Back up $home first?"; then
                backup_home "$username" "$home" || { err "Backup failed, nothing was deleted"; return; }
        fi
        do_cmd userdel -r "$username"
        rc=$?
        case $rc in
                0)  ok "User $username deleted";;
                12) warn "User $username was deleted, but the home directory could not be removed completely";;
                8)  err "$username is logged in, nothing was deleted";;
                *)  err "userdel failed (exit code $rc)";;
        esac
}

delete_user_keep_home() {
        local home uid rc
        need_user || return
        protected_user "$username" && return
        home=$(getent passwd "$username" | cut -d: -f6)
        uid=$(id -u "$username")
        confirm "Delete $username but keep $home?" || { echo "Cancelled"; return; }
        do_cmd userdel "$username"
        rc=$?
        case $rc in
                0) ok "User $username deleted"
                   echo "The home directory $home was kept. Its files are now owned by the number $uid.";;
                8) err "$username is logged in, nothing was deleted";;
                *) err "userdel failed (exit code $rc)";;
        esac
}

delete_group() {
        local gid users members
        need_group || return
        gid=$(getent group "$groupname" | cut -d: -f3)
        if [ "$gid" -lt "$GID_MIN" ] || [ "$gid" -ge "$NOBODY_ID" ]; then
                err "$groupname is a system group (GID $gid), refusing"
                return
        fi
        users=$(getent passwd | awk -F: -v g="$gid" '$4 == g {printf "%s ", $1}')
        if [ -n "$users" ]; then
                err "$groupname is the primary group of: $users"
                return
        fi
        members=$(getent group "$groupname" | cut -d: -f4)
        if [ -n "$members" ]; then
                warn "$groupname still has members: $members (they will lose this group)"
        fi
        confirm "Really delete group $groupname?" || { echo "Cancelled"; return; }
        if do_cmd groupdel "$groupname"; then
                ok "Group $groupname deleted"
        else
                err "groupdel failed"
        fi
}

remove_from_group() {
        need_user || return
        need_group || return
        if [ "$(id -gn "$username")" = "$groupname" ]; then
                err "$groupname is the primary group of $username, change the primary group first"
                return
        fi
        if ! getent group "$groupname" | cut -d: -f4 | tr ',' '\n' | grep -qxF -- "$username"; then
                err "$username is not a member of $groupname"
                return
        fi
        if do_cmd gpasswd -d "$username" "$groupname"; then
                ok "$username removed from $groupname"
        else
                err "gpasswd failed"
        fi
}

list_delete() {
        while true; do
                echo
                echo "[Delete] Welcome to Delete / Remove section"
                echo "[Delete] What do you want to do?"
                echo "[Delete] 1) Delete a user and the home directory (backup possible)"
                echo "[Delete] 2) Delete a user but keep the home directory"
                echo "[Delete] 3) Delete a group"
                echo "[Delete] 4) Remove a user from a group"
                echo "[Delete] 0) Go back a section"
                ask state
                case $state in
                        1) delete_user_with_home;;
                        2) delete_user_keep_home;;
                        3) delete_group;;
                        4) remove_from_group;;
                        0) return;;
                        *) err "Invalid input";;
                esac
        done
}

# ---------- 4) List ----------

show_user_details() {
        need_user || return
        echo "--- id (UID, primary group, all groups) ---"
        id "$username"
        echo "--- passwd entry (name:x:UID:GID:comment:home:shell) ---"
        getent passwd "$username"
        echo "--- password status ---"
        passwd -S "$username"
        echo "--- password aging ---"
        chage -l "$username"
}

show_group_members() {
        local gid
        need_group || return
        gid=$(getent group "$groupname" | cut -d: -f3)
        echo "--- group entry (name:x:GID:members) ---"
        getent group "$groupname"
        echo "--- users with $groupname as their primary group ---"
        getent passwd | awk -F: -v g="$gid" '$4 == g {print $1}'
}

# show regular users whose "passwd -S" status is one of the given codes
show_by_status() {
        local title="$1" u st found=0 code hit
        shift
        echo "$title"
        for u in $(regular_users); do
                st=$(passwd -S "$u" 2> /dev/null | awk '{print $2}')
                hit=0
                for code in "$@"; do
                        [ "$st" = "$code" ] && hit=1
                done
                if [ $hit -eq 1 ]; then
                        echo "  $u"
                        found=1
                fi
        done
        if [ $found -eq 0 ]; then echo "  (none)"; fi
}

show_admins() {
        local g found=0
        echo "Members of the admin groups:"
        for g in sudo wheel admin; do
                if group_exists "$g"; then
                        echo "  $g: $(getent group "$g" | cut -d: -f4)"
                        found=1
                fi
        done
        if [ $found -eq 0 ]; then echo "  (no sudo, wheel or admin group found)"; fi
}

show_logged_in() {
        echo "--- who ---"
        if [ -z "$(who)" ]; then echo "(nobody logged in)"; else who; fi
        echo "--- w ---"
        if have w; then w; else echo "(w is not installed)"; fi
}

show_last() {
        echo "--- last 20 logins (last) ---"
        if have last; then last -n 20 2>&1; else echo "(last is not installed)"; fi
}


show_lastlog() {
        echo "--- last login of each regular user ---"

        if have lastlog; then
                lastlog -u "$UID_MIN-$((NOBODY_ID - 1))" 2>&1

        elif have lastlog2; then
                echo "(Using lastlog2 instead of lastlog)"
                lastlog2 2>&1

        else
                echo "(Neither lastlog nor lastlog2 is installed)"
                echo "Install with: sudo apt install lastlog2 libpam-lastlog2"
        fi
}

show_failed() {
        echo "--- last 10 failed login attempts ---"

        if have lastb; then
                lastb -n 10 2>&1

        elif have lslogins; then
                echo "(Using lslogins as an alternative to lastb)"
                lslogins --failed --user-accs 2>&1 | tail -n 10

        else
                echo "(No failed-login utility found)"
        fi

        echo
        echo "--- last 10 SSH failed login attempts ---"

        if have journalctl; then
                journalctl -u ssh --no-pager -n 100 2>/dev/null |
                        grep -Ei 'failed password|invalid user' |
                        tail -n 10

                echo
                echo "Note: SSH logs only show SSH authentication failures."
        else
                echo "(journalctl is not available)"
        fi

        echo
}

show_expiring() {
        local days u info pexp aexp left msg found=0
        echo "Show accounts expiring within how many days? (Enter for 14)"; ask days
        days="${days:-14}"
        if [[ ! "$days" =~ ^[0-9]+$ ]]; then
                err "Days must be a number"
                return
        fi
        echo "Regular users with an expiring (or expired) password or account:"
        for u in $(regular_users); do
                info=$(LC_ALL=C chage -l "$u")
                pexp=$(echo "$info" | awk -F': ' '/^Password expires/ {print $2}')
                aexp=$(echo "$info" | awk -F': ' '/^Account expires/ {print $2}')
                msg=""
                if [[ "$pexp" == *"must be changed"* ]]; then
                        msg="password change forced at next login"
                elif left=$(days_until "$pexp") && [ "$left" -le "$days" ]; then
                        msg="password $(fmt_days "$left")"
                fi
                if left=$(days_until "$aexp") && [ "$left" -le "$days" ]; then
                        msg="${msg:+$msg, }account $(fmt_days "$left")"
                fi
                if [ -n "$msg" ]; then
                        echo "  $u: $msg"
                        found=1
                fi
        done
        if [ $found -eq 0 ]; then echo "  (none)"; fi
}

list_show() {
        while true; do
                echo
                echo "[List] Welcome to List section"
                echo "[List] What do you want to list?"
                echo "[List] 1) Regular users (UID $UID_MIN+)"
                echo "[List] 2) All users (including system users)"
                echo "[List] 3) Regular groups (GID $GID_MIN+)"
                echo "[List] 4) All groups (including system groups)"
                echo "[List] 5) Details of one user"
                echo "[List] 6) Members of one group"
                echo "[List] 7) Locked accounts"
                echo "[List] 8) Accounts with no password"
                echo "[List] 9) Members of sudo / wheel"
                echo "[List] 10) Who is logged in now (who, w)"
                echo "[List] 11) Login history (last)"
                echo "[List] 12) Last login per user (lastlog)"
                echo "[List] 13) Failed logins (lastb)"
                echo "[List] 14) Passwords / accounts expiring soon"
                echo "[List] 0) Go back a section"
                ask state
                case $state in
                        1) echo "Regular users:"; regular_users | sed 's/^/  /';;
                        2) echo "All users:"; getent passwd | cut -d: -f1 | sed 's/^/  /';;
                        3) echo "Regular groups:"; regular_groups | sed 's/^/  /';;
                        4) echo "All groups:"; getent group | cut -d: -f1 | sed 's/^/  /';;
                        5) show_user_details;;
                        6) show_group_members;;
                        7) show_by_status "Locked regular accounts (L = password locked, SSH keys may still work):" L LK;;
                        8) show_by_status "Regular accounts with no password (NP):" NP;;
                        9) show_admins;;
                        10) show_logged_in;;
                        11) show_last;;
                        12) show_lastlog;;
                        13) show_failed;;
                        14) show_expiring;;
                        0) return;;
                        *) err "Invalid input";;
                esac
        done
}

# ---------- 5) Batch import from CSV ----------

batch_provision() {
        local csv="$1" created=0 skipped=0 failed=0
        local username fullname pgroup sgroups shell maxdays g pw cmd extra_groups bad
        if [ ! -r "$csv" ]; then
                err "Cannot read '$csv'"
                return 1
        fi
        log "INFO  batch start: $csv (dry-run=$DRY_RUN)"
        if [ "$DRY_RUN" -eq 0 ]; then
                # create it (root-only) if missing, but never empty an existing one:
                # it may still hold passwords that were not handed out yet
                ( umask 077; touch "$CRED_FILE" )
        fi

        # the CSV is read on file descriptor 3 so commands in the loop can't eat it;
        # tr removes Windows line endings
        while IFS=, read -r -u 3 username fullname pgroup sgroups shell maxdays; do
                [ -z "$username" ] && continue
                [[ "$username" == \#* ]] && continue
                [ "$username" = "username" ] && continue

                shell="${shell:-$DEFAULT_SHELL}"
                maxdays="${maxdays:-$DEFAULT_MAX_DAYS}"

                if ! valid_name "$username"; then
                        err "invalid username '$username', skipping"
                        failed=$((failed + 1))
                        continue
                fi
                if [ -z "$pgroup" ]; then
                        err "$username: no primary group given, skipping"
                        failed=$((failed + 1))
                        continue
                fi
                if [[ ! "$maxdays" =~ ^[0-9]+$ ]]; then
                        err "$username: max password days '$maxdays' is not a number, skipping"
                        failed=$((failed + 1))
                        continue
                fi
                if ! shell_ok "$shell"; then
                        warn "$username: shell '$shell' is not in /etc/shells, using $DEFAULT_SHELL"
                        shell="$DEFAULT_SHELL"
                fi
                if user_exists "$username"; then
                        echo "SKIP  user '$username' already exists"
                        skipped=$((skipped + 1))
                        continue
                fi

                # groups: check every new group name first, then create the missing ones
                IFS=';' read -ra extra_groups <<< "$sgroups"
                bad=0
                for g in "$pgroup" "${extra_groups[@]}"; do
                        if [ -n "$g" ] && ! group_exists "$g" && ! valid_name "$g"; then
                                err "$username: invalid group name '$g', skipping"
                                bad=1
                        fi
                done
                if [ $bad -eq 1 ]; then
                        failed=$((failed + 1))
                        continue
                fi
                for g in "$pgroup" "${extra_groups[@]}"; do
                        if [ -n "$g" ] && ! group_exists "$g"; then
                                if ! do_cmd groupadd "$g"; then
                                        err "$username: could not create group '$g'"
                                        bad=1
                                fi
                        fi
                done
                if [ $bad -eq 1 ]; then
                        failed=$((failed + 1))
                        continue
                fi

                cmd=(useradd -m -c "$fullname" -g "$pgroup" -s "$shell")
                [ -n "$sgroups" ] && cmd+=(-G "${sgroups//;/,}")
                cmd+=("$username")

                echo "INFO  creating '$username' (group=$pgroup, extra=${sgroups:-none}, shell=$shell)"
                if ! do_cmd "${cmd[@]}"; then
                        err "useradd failed for '$username'"
                        failed=$((failed + 1))
                        continue
                fi

                # random temporary password, must be changed at first login
                pw="$(gen_password)"
                if [ "$DRY_RUN" -eq 0 ]; then
                        if echo "$username:$pw" | chpasswd; then
                                echo "$username:$pw" >> "$CRED_FILE"
                                log "OK    chpasswd $username (temporary password)"
                        else
                                log "FAIL  chpasswd $username"
                                err "$username was created but setting the password failed"
                                failed=$((failed + 1))
                                continue
                        fi
                else
                        echo "  [dry-run] set a random password for $username"
                fi
                do_cmd chage -d 0 "$username" || warn "$username: could not force a password change at first login"
                do_cmd chage -m "$MIN_DAYS" -M "$maxdays" -W "$WARN_DAYS" "$username" || warn "$username: could not set password aging"
                created=$((created + 1))
        done 3< <(tr -d '\r' < "$csv")

        echo
        ok "Batch done: created=$created skipped=$skipped failed=$failed"
        log "INFO  batch done: created=$created skipped=$skipped failed=$failed"
        if [ "$DRY_RUN" -eq 0 ] && [ $created -gt 0 ]; then
                echo "Temporary passwords are in $CRED_FILE (delete it after handing them out)"
        fi
        [ $failed -eq 0 ] || return 2
}

# ---------- start ----------

while getopts "f:nh" opt; do
        case "$opt" in
                f) CSV_FILE="$OPTARG";;
                n) DRY_RUN=1;;
                h) usage; exit 0;;
                *) usage; exit 1;;
        esac
done

# must be root, useradd/groupadd/etc. need it (dry run is allowed without root)
if [ "$DRY_RUN" -eq 0 ] && [ "$EUID" -ne 0 ]; then
        err "Run this script as root (sudo $0)"
        exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
        ( umask 077; touch "$LOG_FILE" ) 2> /dev/null
fi

# Ctrl-C / kill: leave cleanly. EXIT: write the end of the session to the log
trap 'echo; warn "Interrupted, exiting"; exit 130' INT TERM
trap 'log "INFO  session ended"' EXIT
log "INFO  session started (dry-run=$DRY_RUN)"

if [ "$DRY_RUN" -eq 1 ]; then
        warn "DRY RUN: nothing will be changed, commands are only printed"
fi

# batch mode
if [ -n "$CSV_FILE" ]; then
        batch_provision "$CSV_FILE"
        exit $?
fi

# ---------- main menu ----------

while true; do
        echo
        echo "What do you want to do?"
        echo
        echo "1) Create"
        echo "2) Modify / Add"
        echo "3) Delete / Remove"
        echo "4) List"
        echo "5) Batch import from a CSV file"
        echo "0) Exit"

        ask state

        case $state in
                1) list_create;;
                2) list_modify;;
                3) list_delete;;
                4) list_show;;
                5) echo "Path of the CSV file"; ask csvfile; batch_provision "$csvfile";;
                0) echo "Exiting"; exit 0;;
                *) err "Invalid input";;
        esac
done

