#!/usr/bin/env bash
# vim:foldmethod=marker:foldmarker={,}
set -eo pipefail

# Default config / global state
set_defaults() {
  # Defaults
  KEYBOARD_LAYOUT=${KEYBOARD_LAYOUT:-us}
  PRIMARY_LOCALE="en_US.UTF-8 UTF-8"
  TIMEZONE="${TIMEZONE}"

  SYSTEM_HOSTNAME="arch-pc"
  PRIMARY_USERNAME="anon"
  PRIMARY_PASSWORD="1234"

  FS_DISK="/dev/sda"
  FS_ROOT="$FS_DISK""2"
  FS_EFI="$FS_DISK""1"

  # If this is 1, don't mount stuff, just use /mnt as is.
  FS_USE_MNT=0

  # Wipe the disk?
  FS_DO_FDISK=0

  # Format the ESP partition?
  FS_FORMAT_EFI=0
  FS_FORMAT_ROOT=0

  INSTALLER_TITLE="Arch Linux Installer"
  ARCH_MIRROR=""

  # Dialog implementation to use.
  DIALOG=${DIALOG:-dialog}
  DIALOG_OPTS=( \
    --no-collapse \
    --backtitle "$INSTALLER_TITLE (press [Ctrl-C] to exit)" \
    --title " $INSTALLER_TITLE " \
  )

  INSTALL_GRUB=0

  # Recipes
  INSTALL_YAY=0
  INSTALL_SYSTEMD_SWAP=0
  INSTALL_NETWORK_MANAGER=0

  # This variable isn't always available
  LINES="$(tput lines)"
  COLUMNS="$(tput cols)"

  # Dimensions
  WIDTH_LG=$(( $COLUMNS - 4 ))
  WIDTH_SM=60
  WIDTH_MD=72

  # Skip flags
  SKIP_ARCHISO_CHECK=0
  SKIP_EXT4_CHECK=0
  SKIP_MNT_CHECK=0
  SKIP_MOUNTED_CHECK=0
  SKIP_PARTITION_MOUNT_CHECK=0
  SKIP_SANITY_CHECK=0
  SKIP_VFAT_CHECK=0
  SKIP_WELCOME=0
  ENABLE_RECIPES=1

  # Where to write the script
  SCRIPT_FILE="$HOME/arch_installer.sh"
}

set_constants() {
  # Where timezones are stored
  ZONES_PATH="/usr/share/zoneinfo"

  # If keyboard layout matches this, supress setting it
  DEFAULT_KEYBOARD_LAYOUT="us"

  # Label for skipping a boot loader
  NO_BOOTLOADER="Skip"
  ADD_NEW_TAG="None"

  # Installer URL
  INSTALLER_URL="https://github.com/rstacruz/arch-installer"

  # Where the ESP partition is to be mounted
  ESP_PATH="/boot"

  EDITOR=${EDITOR:-nano}
}

# Start everything
main() {
  app:infer_defaults
  app:parse_options "$@"

  if [[ "$SKIP_SANITY_CHECK" != 1 ]]; then
    check:ensure_pacman
    check:ensure_available_utils
    check:ensure_efi
    check:ensure_online
  fi

  if [[ "$SKIP_ARCHISO_CHECK" != 1 ]]; then
    check:ensure_hostname
  fi

  if [[ "$SKIP_WELCOME" != 1 ]]; then
    welcome:show_dialog
  fi

  # Configure the disk first
  disk:config_strategy

  # (FS_ROOT will be blank if /mnt is to be used.)
  if [[ "$FS_USE_MNT" == "0" ]] && [[ "$FS_ROOT" == "$FS_EFI" ]]; then
    quit:invalid_partition_selection
  fi

  if [[ "$FS_USE_MNT" == 1 ]]; then
    disk:show_mnt_warning
  else
    disk:confirm_strategy
  fi

  # Configure locales and such
  config:system

  # Configure your user
  config:user

  # Write the script, then show debriefing dialogs
  script:write
  confirm:run
}

# -------------------------------------------------------------------------------

# Ensures that the system is booted in UEFI mode, and not
# Legacy mode. Exits the installer if it fails.
check:ensure_efi() {
  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    quit:not_efi
  fi
}

# Exits the installer if were offline.
check:ensure_online() {
  if ! ping -c 1 -W 1 8.8.8.8 &>/dev/null; then
    echo "You don't seem to be online."
    exit 1
  fi
}

check:ensure_hostname() {
  if [[ "$(hostname)" != "archiso" ]]; then
    quit:wrong_hostname
  fi
}

check:ensure_available_utils() {
  check:ensure_util util-linux mount
  check:ensure_util util-linux lsblk
  check:ensure_util dialog dialog
  check:ensure_util arch-install-scripts arch-chroot
  check:ensure_util arch-install-scripts pacstrap
}

check:ensure_util() {
  local pkg="$1"
  local exec="$2"
  if ! which "$exec" &>/dev/null; then
    quit:missing_util "$exec" "$pkg"
  fi
}

# Ensure that Pacman is installed.
check:ensure_pacman() {
  if [[ ! -e /etc/pacman.d/mirrorlist ]]; then
    quit:not_arch
  fi
}

# Ensure there are available partitions.
check:ensure_valid_partitions() {
  disk="$1"
  if [[ "$SKIP_EXT4_CHECK" == 0 ]]; then
    if ! util:disk_has_partition "$disk" "ext4"; then
      quit:no_ext4
    fi
  fi

  if [[ "$SKIP_VFAT_CHECK" == 0 ]]; then
    if ! util:disk_has_partition "$disk" "vfat"; then
      quit:no_vfat
    fi
  fi
}

check:not_mounted() {
  if [[ "$SKIP_MOUNTED_CHECK" != 0 ]]; then return; fi
  local disk="$1"
  if findmnt -o SOURCE | grep "$disk" &>/dev/null; then
    quit:disk_is_mounted "$disk"
  fi
}

# -------------------------------------------------------------------------------

# Configure keyboard layout, timezone, locale
config:system() {
  set +e; while true; do
    choice="$(config:show_system_dialog)"
    case "$?" in
      0)
        case "$choice" in
          Keyboard\ layout)
            choice="$(config:choose_keyboard_layout "$KEYBOARD_LAYOUT")"
            if [[ -n "$choice" ]]; then
              KEYBOARD_LAYOUT="$choice"
              loadkeys "$choice"
            fi
            ;;
          Time\ zone)
            choice="$(config:choose_timezone "$TIMEZONE")"
            if [[ -n "$choice" ]]; then TIMEZONE="$choice"; fi
            ;;
          Locales)
            choice="$(config:choose_locale)"
            if [[ -n "$choice" ]]; then PRIMARY_LOCALE="$choice"; fi
            ;;
        esac
        ;;
      3) break ;; # "Next"
      *) quit:exit ;; # "Cancel"
    esac
  done; set -e
}

# Pick Linux partition ($FS_ROOT)
config:pick_root_partition() {
  choice="$(config:show_partition_dialog \
    --add "$ADD_NEW_TAG" "...Add a new partition" \
    "$FS_DISK" \
    "Linux partition" \
    "Choose partition to install Linux into:\n(This is usually an 'ext4' partition.)")"
  if [[ "$choice" == "$ADD_NEW_TAG" ]]; then
    quit:cfdisk "$FS_DISK"
  else
    FS_ROOT="$choice"
  fi
}

# Pick EFI partition ($FS_EFI)
config:pick_efi_partition() {
  body="Choose partition to install the EFI boot loader into:"
  subtext="This should be an EFI partition, typically a fat32."
  choice="$(config:show_partition_dialog \
    --add "$ADD_NEW_TAG" "...Add a new partition" \
    --add "$NO_BOOTLOADER" "...Don't install a boot loader" \
    "$FS_DISK" \
    "EFI Partition" \
    "$body\n$subtext")"
  if [[ "$choice" == "$NO_BOOTLOADER" ]]; then
    FS_EFI=""
  elif [[ "$choice" == "$ADD_NEW_TAG" ]]; then
    quit:cfdisk "$FS_EFI"
  else
    INSTALL_GRUB=1
    FS_EFI="$choice"
  fi
}

config:show_disk_dialog() {
  pairs=()
  IFS=$'\n'
  while read line; do
    eval "$line"
    pairs+=("/dev/$NAME" "$SIZE")
  done <<< $(util:list_drives)

  local warning=
  local title="Which disk do you want to install Arch Linux into?"

  if [[ "$1" == "--wipe" ]]; then
    warning="(This entire disk will be wiped!)"
  else
    warning="(Pick partitions from this drive in the next screen.)"
  fi

  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " Disks " \
    --no-cancel \
    --ok-label "Next" \
    --menu "\n$title\n$warning\n " \
    14 $WIDTH_SM 4 \
    ${pairs[*]} \
    3>&1 1>&2 2>&3
}

# Lets the user select a partition
config:show_partition_dialog() {
  local extra_pairs=()

  while true; do
    case "$1" in
      --add)
        extra_pairs+=("$2" "$3")
        shift; shift; shift
        ;;
      *)
        break ;;
    esac
  done

  local disk="$1"
  local title="$2"
  local body="$3"
  local pairs=()

  # Add partition to `$pairs`
  IFS=$'\n'
  while read line; do
    eval "$line"
    label="$(printf "[%8s]  %s - %s" "$SIZE" "$FSTYPE" "${LABEL:-No label}")"
    pairs+=("/dev/$NAME" "$label")
  done <<< $(util:list_partitions "$disk")

  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " $title " \
    --no-cancel \
    --ok-label "Next" \
    --menu "\n$body\n " \
    17 $WIDTH_SM 8 \
    ${pairs[*]} \
    ${extra_pairs[*]} \
    3>&1 1>&2 2>&3
}

# Returns (echoes) a timezone. `$1` currently-selected one.
#     config:choose_timezone "Asia/Manila"
config:choose_timezone() {
  active="$1"
  choice="$(form:file_picker \
    "$ZONES_PATH" \
    "Time zone" \
    "Choose your region:"
  )"
  if [[ -z "$choice" ]]; then echo $active; return; fi
  echo $choice
}

# Returns (echoes) a keyboard layout.
config:choose_keyboard_layout() {
  active="$1"
  (
    echo us
    echo uk
    echo dvorak
    echo colemak
    util:list_keymaps
  ) | form:select \
    "Keyboard layout" \
    "$active"
}

# Returns (echoes) a locale.
config:choose_locale() {
  (
    echo "en_US.UTF-8 UTF-8"
    echo "en_GB.UTF-8 UTF-8"
    util:list_locales
  ) | form:multi_select \
    "Locales"
}

# -------------------------------------------------------------------------------

# Configure disk strategy (partition, wipe, /mnt)
disk:config_strategy() {
  strategy="$(disk:choose_strategy_dialog)"
  case "$strategy" in
    Partition*)
      quit:cfdisk
      ;;

    Wipe*)
      choice="$(config:show_disk_dialog --wipe)"
      FS_DISK="$choice"
      check:not_mounted "$FS_DISK"
      FS_DO_FDISK=1
      INSTALL_GRUB=1
      FS_FORMAT_EFI=1
      FS_FORMAT_ROOT=1
      ;;

    Use\ /mnt*)
      if ! util:is_mnt_mounted; then quit:mnt_not_mounted; fi
      FS_USE_MNT=1
      FS_ROOT=""
      FS_EFI=""
      ;;

    Choose*)
      choice="$(config:show_disk_dialog --format)"
      FS_DISK="$choice"

      # Are the required partitions available?
      check:ensure_valid_partitions "$FS_DISK"

      # Pick other patitions
      config:pick_root_partition
      config:pick_efi_partition

      # Check them if they can be mounted
      if [[ "$SKIP_PARTITION_MOUNT_CHECK" == "0" ]]; then
        validate_partition:show_warning
        validate_partition:efi
        validate_partition:root
      fi
      ;;
  esac
}

# (partition, wipe, /mnt)
disk:choose_strategy_dialog() {
  local title="How do you want to install Arch Linux on your drive?"

  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " Disk strategy " \
    --no-cancel \
    --ok-label "Next" \
    --menu "\n$title\n " \
    14 $WIDTH_MD 4 \
    "Wipe drive" "Wipe my drive completely." \
    "Choose partitions" "I've already partitioned my disks." \
    "Partition manually" "Let me partition my disk now." \
    "Use /mnt" "(Advanced) Use whatever is mounted on /mnt." \
    3>&1 1>&2 2>&3
}

review:get_disk_strategy() {
  message=""
  if [[ "$FS_DO_FDISK" == 1 ]]; then
    message+="\n\n\Zb\Z3Wipe $FS_DISK (!)\Zn\n"
    message+="The entire disk will be wiped. It will be initialized with a fresh, new \ZbGPT\Zn partition table. \ZbAll of its data will be erased.\Zn"

    message+="\n\n\Zb\Z2Create new EFI partition ($FS_EFI)\Zn\n"
    message+="This partition will be reformatted, and a new boot loader be put in its place."

    message+="\n\n\Zb\Z2Create new Arch Linux partition ($FS_ROOT)\Zn\n"
    message+="This new partition will be reformatted as \Zbext4\Zn, and Arch Linux will be installed here."
  else
    if [[ "$FS_FORMAT_EFI" == 1 ]]; then
      message+="\n\n\Zb\Z2Format the EFI partition, $(util:partition_info $FS_EFI)\Zn\n"
      message+="This partition will be reformatted. A GRUB boot loader entry will be placed there."
    elif [[ -n "$FS_EFI" ]]; then
      message+="\n\n\Zb\Z2Add boot loader to $(util:partition_info $FS_EFI)\Zn\n"
      message+="A new GRUB boot loader entry will be added to \Zb$FS_EFI\Zn. It won't be reformatted. Any existing boot loaders will be left untouched."
    else
      message+="\n\n\Zb\Z2No boot loader will be installed\Zn\n"
      message+="You will need to install a boot loader yourself (eg, GRUB)."
    fi
    if [[ "$FS_FORMAT_ROOT" == 1 ]]; then
      message+="\n\n\Zb\Z2Format the root partition, $(util:partition_info $FS_ROOT)\Zn\n"
      message+="This existing partition will be reformatted as \Zbext4\Zn, and Arch Linux will be installed here."
    elif [[ -n "$FS_ROOT" ]]; then
      message+="\n\n\Zb\Z2Install Arch Linux to $(util:partition_info $FS_ROOT)\Zn\n"
      message+="Arch Linux will be installed into this existing partition. It won't be reformatted."
    fi
  fi
  # TODO: Warn if certain partition types are not supported
  echo "$message"
}

# Show the user what's about to happen
disk:confirm_strategy() {
  message=""
  message+="These operations will be done to your disk:"
  message+="\n\Z1───────────────────────────────────────────────────────────────────\Zn"
  message+="$(review:get_disk_strategy)"
  message+="\n"
  message+="\n\Z1───────────────────────────────────────────────────────────────────\Zn"
  message+="\nPress \ZbNext\Zn and we'll continue configuring your installation, or \Zbctrl-c\Zn to exit. None of these operations will be done until the final step."

  $DIALOG "${DIALOG_OPTS[@]}" \
    --colors \
    --title " Review " \
    --ok-label "Next" \
    --msgbox "$message" \
    23 $WIDTH_MD \
    3>&1 1>&2 2>&3
}

# -------------------------------------------------------------------------------

# Dropdown
form:select() {
  title="$1"
  active="$2"
  pairs=()
  IFS=$'\n'
  while read line; do
    pairs+=("$line" "$line")
  done

  $DIALOG "${DIALOG_OPTS[@]}" \
    --no-tags \
    --title " $title " \
    --default-item "$active" \
    --menu "" \
    23 $WIDTH_SM 16 \
    ${pairs[*]} \
    3>&1 1>&2 2>&3
}

# Multi-select dropdown
form:multi_select() {
  title="$1"
  active="$2"
  pairs=()
  IFS=$'\n'
  while read line; do
    status=off
    if [[ "${active[@]}" =~ "${line}" ]]; then status=on; fi
    pairs+=("$line" "$line" $status)
  done

  $DIALOG "${DIALOG_OPTS[@]}" \
    --no-tags \
    --separate-output \
    --title " $title " \
    --checklist "Press [SPACE] to select/deselect." \
    23 $WIDTH_SM 16 \
    ${pairs[*]} \
    3>&1 1>&2 2>&3
}

# A file picker dialog of sorts
#     form:file_picker /path/to "Title" "Pick a file:"
form:file_picker() {
  root="$1"
  title="$2"
  body="$3"
  depth="0"
  result=""

  while true; do
    choice="$(form:file_picker_dialog "$root" "$title" "$body" "$depth")"
    if [[ $? != 0 ]]; then
      return 1
    fi
    result="${result}${choice}"
    if [[ -f "$root/$choice" ]]; then
      break
    else
      root="$root/$choice"
    fi
    depth="$(( $depth + 1 ))"
  done
  echo "$result"
}

# Delegate function of form:file_picker
form:file_picker_dialog() {
  root="$1"
  title="$2"
  body="$3"
  depth="$4"

  pairs=()
  for entry in "$root"/*; do
    # For the first-level, ignore non-files.
    if [[ $depth == 0 ]] && [[ ! -d "$entry" ]]; then continue; fi
    if [[ -d "$entry" ]]; then entry="$entry/"; fi

    # Strip the root from it
    entry=${entry#$root/}

    # These directories should be ignored for timezones
    if [[ "$entry" == "right/" ]]; then continue; fi
    if [[ "$entry" == "posix/" ]]; then continue; fi

    pairs+=("$entry" "$entry")
  done

  $DIALOG "${DIALOG_OPTS[@]}" \
    --no-tags \
    --title " $title " \
    --menu "$body" \
    23 $WIDTH_SM 16 \
    ${pairs[*]} \
    3>&1 1>&2 2>&3
}

# -------------------------------------------------------------------------------

# List available keymaps
util:list_keymaps() {
  find /usr/share/kbd/keymaps -type f -exec basename '{}' '.map.gz' \; | sort
}

# List available locales
util:list_locales() {
  cat /etc/locale.gen | grep -e '^#[a-zA-Z]' | sed 's/^#//g' | sed 's/ *$//g'
}

# Check if a disk has a given partition of given type
#     if util:disk_has_partition /dev/sda1 ext4; then ...
util:disk_has_partition() {
  disk="$1"
  fstype="$2"
  lsblk -I 8 -o "NAME,SIZE,TYPE,FSTYPE,LABEL" -P \
    | grep 'TYPE="part"' \
    | grep "$(basename $disk)" \
    | grep "FSTYPE=\"$fstype\"" \
    &>/dev/null
}

# -------------------------------------------------------------------------------

# Form helper
form:text_input() {
  label="$1"
  value="$2"
  description="$3"
  $DIALOG "${DIALOG_OPTS[@]}" \
    --title "" \
    --no-cancel \
    --inputbox \
    "$label\n$description" \
    10 $WIDTH_SM \
    "$value" \
    3>&1 1>&2 2>&3
}

# Config: Show system dialog
config:show_system_dialog() {
  message="\nYou can <Change> any of these settings. Move to the <Next> screen when you're done.\n "
  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " Locales " \
    --no-cancel \
    --ok-label "Change" \
    --extra-button \
    --extra-label "Next" \
    --menu "$message" \
    14 $WIDTH_SM 3 \
    "Keyboard layout" "[$KEYBOARD_LAYOUT]" \
    "Time zone" "[$TIMEZONE]" \
    "Locales" "[$(echo "${PRIMARY_LOCALE}" | xargs echo)]" \
    3>&1 1>&2 2>&3
}

config:user() {
  set +e; while true; do
    choice="$(config:show_user_dialog)"
    case "$?" in
      0)
        case "$choice" in
          System\ hostname)
            SYSTEM_HOSTNAME=$( \
              form:text_input \
              "System hostname:" "$SYSTEM_HOSTNAME" \
              "This is how your system will identify itself in networks. Think of this like the name of your computer.")
            ;;
          Your\ username)
            PRIMARY_USERNAME=$(\
              form:text_input \
              "Username:" "$PRIMARY_USERNAME" \
              "This is the user you will be using on a day-to-day basis.")
            ;;
          Your\ password)
            PRIMARY_PASSWORD=$( \
              form:text_input \
              "Password:" "$PRIMARY_PASSWORD" \
              "Password for your primary user. (You can always change this later!)"
            )
            ;;
        esac
        ;;
      3) break ;; # "Next"
      *) quit:exit ;; # "Cancel"
    esac
  done; set -e
}

# Let the user pick recipes they want
config:recipes() {
  result="$(config:show_recipes_dialog)"
  INSTALL_YAY=0
  INSTALL_NETWORK_MANAGER=0
  INSTALL_SYSTEMD_SWAP=0
  for item in $result; do
    case "$item" in
      yay) INSTALL_YAY=1 ;;
      networkmanager) INSTALL_NETWORK_MANAGER=1 ;;
      systemd-swap) INSTALL_SYSTEMD_SWAP=1 ;;
    esac
  done
}

config:show_recipes_dialog() {
  body="Pick some other extras to install.\n"
  body+="Press [space] to select or deselect items."
  $DIALOG "${DIALOG_OPTS[@]}" \
    --separate-output \
    --no-cancel \
    --ok-label "OK" \
    --title " Extras " \
    --checklist "\n$body\n " \
    15 $WIDTH_LG 8 \
    "yay" "Install yay, the AUR helper" \
    $([[ $INSTALL_YAY == "1" ]] && echo on || echo off) \
    "networkmanager" "Install NetworkManager" \
    $([[ $INSTALL_NETWORK_MANAGER == "1" ]] && echo on || echo off) \
    "systemd-swap" "Manage swap files with systemd-swap" \
    $([[ $INSTALL_SYSTEMD_SWAP == "1" ]] && echo on || echo off) \
    3>&1 1>&2 2>&3
}

# Config: Show user dialog
config:show_user_dialog() {
  message="\nTell me about the user you're going to use day-to-day.\n "
  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " Configure your user " \
    --no-cancel \
    --no-shadow \
    --ok-label "Change" \
    --extra-button \
    --extra-label "Next" \
    --menu "$message"\
    13 $WIDTH_SM 3 \
    "System hostname" "[$SYSTEM_HOSTNAME]" \
    "Your username" "[$PRIMARY_USERNAME]" \
    "Your password" "[$PRIMARY_PASSWORD]" \
    3>&1 1>&2 2>&3
}

# -------------------------------------------------------------------------------

# Inform the user why they'll be asked for a sudo password.
# (When ran from the arch installer, there's no need to sudo,
# so there's no need for this warning either.)
validate_partition:show_warning() {
  clear
  if ! util:is_root; then
    echo ""
    echo "Your partitions will be mounted now in read-only mode to check"
    echo "if they're already formatted."
    echo ""
  fi
}

# See if the EFI partition is mountable.
validate_partition:efi() {
  # If there's no EFI to be checked (eg, skip bootloader)
  # then don't check
  if [[ -z "$FS_EFI" ]]; then return; fi

  validate_partition:check_if_mounted "$FS_EFI"
  if ! validate_partition:check "$FS_EFI"; then
    quit:format_efi_first "$FS_EFI"
  fi
}

validate_partition:check_if_mounted() {
  if [[ "$SKIP_MOUNTED_CHECK" != 0 ]]; then return; fi
  local dev="$1"
  local target=$(findmnt "$dev" -no 'TARGET')
  if [[ -n "$target" ]]; then
    quit:already_mounted "$dev" "$target"
  fi
}

# See if the root partition is mountable.
validate_partition:root() {
  validate_partition:check_if_mounted "$FS_ROOT"
  if ! validate_partition:check "$FS_ROOT"; then
    quit:format_root_first "$FS_ROOT"
  fi
}

# See if a partition is mountable.
validate_partition:check() {
  local dev="$1"
  set +e
  local mountpoint="/tmp/mount"

  # Mount it, save the result to check later
  util:sudo "mkdir -p $mountpoint"
  util:sudo "mount -o ro $dev $mountpoint"
  result="$?"

  # Force-unmount it
  util:sudo "umount $mountpoint" || true
  util:sudo "rmdir $mountpoint"

  if [[ "$result" != "0" ]]; then
    return 1
  fi
}

# -------------------------------------------------------------------------------

# Show welcome message
welcome:show_dialog() {
  message="
$(utils:arch_logo)

Welcome to Arch Linux! Lets get started. Before we begin, let's go
over a few things:

- This installer will not do anything until the end. It's safe to
  navigate this installer's options. There will be a confirmation
  dialog at the end of this process; nothing destructive will be
  done before that.

- Press [Ctrl-C] at any time to exit this installer.

- Be sure to read the Arch Linux wiki. There's no substitute to
  understanding everything that's happening :)

  $INSTALLER_URL
  "
  $DIALOG "${DIALOG_OPTS[@]}" \
    --ok-label "Next" \
    --msgbox "$message" \
    "$(( $LINES - 8 ))" $WIDTH_MD
}

# -------------------------------------------------------------------------------

# Confirmation step
confirm:run() {
  choice="$(confirm:show_confirm_dialog)"
  case "$choice" in
    Install*) app:edit_script; app:run_script ;;
    Review*) confirm:show_script_dialog; confirm:run ;;
    Additional*) config:recipes; script:write; confirm:run ;;
    *) quit:exit ;;
  esac
}

confirm:show_script_dialog() {
  # "$EDITOR" "$SCRIPT_FILE"
  # less "$SCRIPT_FILE"
  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " $SCRIPT_FILE " \
    --exit-label "Continue" \
    --textbox "$SCRIPT_FILE" $(( $LINES - 2 )) $WIDTH_LG
}

confirm:show_confirm_dialog() {
  local message="\n"
  message+="Ready to install!\n"
  message+="An install script's been prepared for you. You can run it now by selecting \ZbInstall now\Zn.\n"
  message+=" "

  local recipe_opts=("Additional options..." "")
  if [[ "$ENABLE_RECIPES" != 1 ]]; then recipe_opts=(); fi
  
  $DIALOG "${DIALOG_OPTS[@]}" \
    --title " Install now " \
    --no-cancel \
    --colors \
    --ok-label "Go!" \
    --menu "$message" \
    17 $WIDTH_SM 4 \
    "Install now" "" \
    "Review script" "" \
    "${recipe_opts[@]}" \
    "Exit installer" "" \
    3>&1 1>&2 2>&3
}

# -------------------------------------------------------------------------------

app:edit_script() {
  set +e
  body="Edit this install script before installing?"

  $DIALOG "${DIALOG_OPTS[@]}" \
    --keep-window \
    --title " $SCRIPT_FILE " \
    --exit-label "Continue" \
    --textbox "$SCRIPT_FILE" $(( $LINES - 2 )) $WIDTH_LG \
    --and-widget \
    --title "" \
    --yes-label "Edit and Install" \
    --no-label "Just Install Now" \
    --yesno "\n$body\n " \
    7 $WIDTH_SM \
    3>&1 1>&2 2>&3
  
  case "$?" in
    0)
      "$EDITOR" "$SCRIPT_FILE"
      reset # Vim can sometimes leave some ANSI garbage
      ;;
  esac
}

# Run the script
app:run_script() {
  # Only proceed if we're root.
  if [[ $(id -u) != "0" ]]; then quit:exit; return; fi

  # Clear the screen
  clear

  bash "$SCRIPT_FILE"
}

# -------------------------------------------------------------------------------

# Write script
script:write() {
  script:write_start
  script:write_pre_hints

  if [[ "$FS_DO_FDISK" == "1" ]]; then
    script:write_fdisk
  fi

  script:write_pacstrap
  script:write_recipes
  script:write_hints
  script:write_end
}

script:write_start() {
  (
    echo '#!/usr/bin/env bash'
    echo "#"
    echo "#  ------------------------------------------------------------------"
    echo "#  Please review the install script below."
    echo "#  ------------------------------------------------------------------"
    echo "#  This file was saved to $SCRIPT_FILE."
    echo "#  ------------------------------------------------------------------"
    echo "#"
    echo "set -euo pipefail"
    echo '::() { echo -e "\n\033[0;1m==>\033[1;32m" "$*""\033[0m"; }'
    echo 'if [[ "$(id -u)" != 0 ]]; then :: "Please run this as root"; exit 1; fi'
    echo ''
  ) > "$SCRIPT_FILE"
  chmod +x "$SCRIPT_FILE"
}

script:write_pre_hints() {
  cat >> "$SCRIPT_FILE" <<EOF
### Tip: Uncomment below to edit the mirror list before installing!
# $EDITOR /etc/pacman.d/mirrorlist; reset
EOF
  echo '' >> "$SCRIPT_FILE"
}

script:write_fdisk() {
  (
    echo ":: 'Wiping disk ($FS_DISK)'"
    echo "("
    echo "  echo g      # Clear everything and start as GPT"
    echo "  echo w      # Write and save"
    echo ") | fdisk $FS_DISK"
    echo ""
    echo ":: 'Creating partitions in $FS_DISK'"
    echo "("
    echo "  echo n      # New partition"
    echo "  echo 1      # .. partition number = 1"
    echo "  echo ''     # .. start sector = default"
    echo "  echo +250M  # .. last sector"
    echo "  echo t      # Change type"
    echo "  echo 1      # .. type = 1 (EFI)"
    echo "  echo n      # New partition"
    echo "  echo 2      # .. partition number = 1"
    echo "  echo ''     # .. start sector = default"
    echo "  echo ''     # .. last sector = default"
    echo "  echo t      # Change type"
    echo "  echo 2      # .. partition number = 2"
    echo "  echo 20     # .. Linux filesystem"
    echo "  echo w      # Write and save"
    echo ") | fdisk $FS_DISK"
    echo ''
  ) >> "$SCRIPT_FILE"
}

script:write_pacstrap() {
  (
    echo ":: 'Enabling clock syncing via ntp'"
    echo "timedatectl set-ntp true"
    echo ''
    if [[ "$FS_USE_MNT" == "1" ]]; then
      echo ":: 'Using /mnt'"
      echo '# (Not mounting any drives, assuming /mnt is already available.)'
      echo ''
    else
      if [[ "$FS_FORMAT_EFI" == "1" ]]; then
        echo ":: 'Formating ESP partition ($FS_EFI)'"
        echo "mkfs.fat -F32 $FS_EFI"
        echo ''
      fi
      if [[ "$FS_FORMAT_ROOT" == "1" ]]; then
        echo ":: 'Formating primary partition ($FS_ROOT)'"
        echo "mkfs.ext4 $(esc "$FS_ROOT")"
        echo ''
      fi
      echo ":: 'Mounting partitions'"
      echo "mount $FS_ROOT /mnt"
      if [[ "$FS_EFI" != "$NO_BOOTLOADER" ]]; then
        echo "mkdir -p /mnt$ESP_PATH"
        echo "mount $FS_EFI /mnt$ESP_PATH"
      fi
      echo ''
    fi
    echo ":: 'Starting pacstrap installer'"
    echo "pacstrap /mnt base"
    echo ''
    echo ":: 'Generating fstab'"
    echo "genfstab -U /mnt >> /mnt/etc/fstab"
    echo ''
    echo ":: 'Setting timezone'"
    echo "arch-chroot /mnt sh <<END"
    echo "  ln -sf /usr/share/zoneinfo/$(esc "$TIMEZONE") /etc/localtime"
    echo "  hwclock --systohc"
    echo "END"
    echo ''
    echo ":: 'Setting locales'"
    echo "arch-chroot /mnt sh <<END"
    (
      IFS=$'\n'
      for locale in ${PRIMARY_LOCALE[*]}; do
        echo "  echo $(esc "$locale") >> /etc/locale.gen"
      done
      echo "  echo LANG=$(esc $(util:get_primary_locale)) > /etc/locale.conf"
    )
    echo "  locale-gen"
    echo "END"
    echo ''
    if [[ "$KEYBOARD_LAYOUT" != "$DEFAULT_KEYBOARD_LAYOUT" ]]; then
      echo ":: 'Making keyboard layout persist on boot'"
      echo "arch-chroot /mnt sh <<END"
      echo "  echo KEYMAP=$(esc "$KEYBOARD_LAYOUT") > /etc/vconsole.conf"
      echo "END"
      echo ''
    fi
    echo ":: 'Setting hostname'"
    echo "arch-chroot /mnt sh <<END"
    echo "  echo $(esc "$SYSTEM_HOSTNAME") > /etc/hostname"
    echo "  echo '127.0.0.1 localhost' >> /etc/hosts"
    echo "  echo '::1 localhost' >> /etc/hosts"
    echo "  echo '127.0.1.1 $SYSTEM_HOSTNAME.localdomain $SYSTEM_HOSTNAME' >> /etc/hosts"
    echo "END"
  ) >> "$SCRIPT_FILE"
}

script:write_recipes() {
  (
    if [[ "$INSTALL_GRUB" == "1" ]]; then
      recipes:setup_grub
    fi
    recipes:create_user
    recipes:install_sudo
    if [[ "$INSTALL_YAY" == "1" ]]; then
      recipes:install_yay
    fi
    if [[ "$INSTALL_NETWORK_MANAGER" == "1" ]]; then
      recipes:install_network_manager
    fi
    if [[ "$INSTALL_SYSTEMD_SWAP" == "1" ]]; then
      recipes:install_systemd_swap
    fi
  ) >> "$SCRIPT_FILE"
}

script:write_hints() {
  echo '' >> "$SCRIPT_FILE"
  cat >> "$SCRIPT_FILE" <<EOF
# By now installation is done! Here are a few more things you can try.
# You can uncomment them below, or do them after the installation.
arch-chroot /mnt sh <<END
  ### Intel video driver, needed for some laptops
  # pacman -S --noconfirm xf86-video-intel

  ### NVidia video driver
  # pacman -S --noconfirm xf86-video-nouveau

  ### Lightdm greeter (login screen)
  # pacman -S --noconfirm xorg-server lightdm lightdm-gtk-greeter
  # systemctl enable lightdm

  ### Install a desktop environment (pick one or more)
  ### (for GNOME, don't install lightdm; gdm better integrates with it.)
  # pacman -S --noconfirm xfce4
  # pacman -S --noconfirm gnome gdm; systemctl enable gdm
  # pacman -S --noconfirm plasma
  # pacman -S --noconfirm i3-gaps rxvt-unicode

  ### Install a browser
  # pacman -S --noconfirm chromium
  # pacman -S --noconfirm firefox

  ### For VirtualBox guests
  # yay -S --noconfirm virtualbox-guest-dkms
END
EOF
}

script:write_end() {
  (
    echo ""
    echo "echo ''"
    echo "echo \"  ┌──────────────────────────────────────────┐\""
    echo "echo \"  │ You're done!                             │\""
    echo "echo \"  │ Type 'reboot' and remove your USB drive. |\""
    echo "echo \"  └──────────────────────────────────────────┘\""
    echo "echo ''"
    echo ""
    # TODO: warn that grub is not installed if INSTALL_GRUB=0
    echo "# Generated by $INSTALLER_TITLE ($INSTALLER_URL)"
  ) >> "$SCRIPT_FILE"
}

# -------------------------------------------------------------------------------

# Recipe for setting up grub
recipes:setup_grub() {
  echo ''
  echo ":: 'Installing GRUB boot loader'"
  echo "arch-chroot /mnt sh <<END"
  echo "  pacman -Syu --noconfirm grub efibootmgr"
  echo "  grub-install --target=x86_64-efi --efi-directory=$ESP_PATH --bootloader-id=GRUB"
  echo "  grub-mkconfig -o $ESP_PATH/grub/grub.cfg"
  echo "END"
}

# Recipe for creating user
recipes:create_user() {
  echo ''
  echo ":: 'Creating user $(esc "$PRIMARY_USERNAME")'"
  echo "arch-chroot /mnt sh <<END"
  echo "  useradd -Nm -g users -G wheel,sys $(esc "$PRIMARY_USERNAME")"
  echo "  echo -e $(esc "$PRIMARY_PASSWORD")\"\\n\"$(esc "$PRIMARY_PASSWORD") | passwd $(esc "$PRIMARY_USERNAME")"
  echo "END"
}

# Recipe for installing sudo
recipes:install_sudo() {
  echo ''
  echo ":: 'Setting up sudo'"
  echo "arch-chroot /mnt sh <<END"
  echo "  pacman -Syu --noconfirm sudo"
  echo "  echo '%wheel ALL=(ALL) ALL' | sudo EDITOR='tee -a' visudo"
  echo "END"
}

# Install yay, the aur helper
# this doesn't work right now lol
recipes:install_yay() {
  echo ''
  echo ":: 'Setting up yay'"
  echo "# Yay is an AUR helper. See: https://github.com/Jguer/yay"
  echo "arch-chroot /mnt bash <<END"
  echo "  # Enable colors in Pacman. Not needed, but why not?"
  echo "  sed -i 's/^#Color/Color/' /etc/pacman.conf"
  echo ""
  echo "  # Install dependencies"
  echo "  pacman -Syu --noconfirm --needed git base-devel"
  echo "  cd /home/$(esc "$PRIMARY_USERNAME")"
  echo ""
  echo "  # Download PKGBUILD and built it"
  echo "  rm -rf yay-bin"
  echo "  su $(esc "$PRIMARY_USERNAME") -c 'git clone https://aur.archlinux.org/yay-bin.git'"
  echo "  cd yay-bin"
  echo "  su $(esc "$PRIMARY_USERNAME") -c 'makepkg'"
  echo ""
  echo "  # Install"
  echo "  pacman -U --noconfirm yay-bin*.tar.xz"
  echo ""
  echo "  # Clean up"
  echo "  cd .."
  echo "  rm -rf yay-bin"
  echo "END"
}

recipes:install_network_manager() {
  echo ''
  echo ":: 'Setting up network manager'"
  echo "arch-chroot /mnt bash <<END"
  echo "  pacman -Syu --noconfirm --needed networkmanager"
  echo "  systemctl enable NetworkManager"
  echo "END"
}

recipes:install_systemd_swap() {
  echo ''
  echo ":: 'Setting up systemd-swap'"
  echo "arch-chroot /mnt bash <<END"
  echo "  pacman -Syu --noconfirm --needed systemd-swap"
  echo "  sed -i 's/swapfc_enabled=0/swapfc_enabled=1/' /etc/systemd/swap.conf"
  echo "  systemctl enable systemd-swap"
  echo "END"
}

# -------------------------------------------------------------------------------

# Infer some default values
app:infer_defaults() {
  if [[ -z "$TIMEZONE" ]]; then
    TIMEZONE=$(timedatectl | grep 'Time zone' | awk '{ print $3 }')
  fi

  if [[ "$(whoami)" != "root" ]]; then
    PRIMARY_USERNAME="$(whoami)"
  fi

  if [[ -f /etc/vconsole.conf ]]; then
    {
      set +e
      local keymap="$(grep 'KEYMAP=' /etc/vconsole.conf | cut -d'=' -f2)"
      if [[ -n "$keymap" ]]; then
        KEYBOARD_LAYOUT="$keymap"
      fi
    }
  fi
}

# Parse options
app:parse_options() {
  while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
    --vip)
      # Go through the VIP entrance and skip some checkpoints.
      # Use this only for testing purposes!
      SKIP_ARCHISO_CHECK=1
      SKIP_EXT4_CHECK=1
      SKIP_MNT_CHECK=1
      SKIP_MOUNTED_CHECK=1
      SKIP_SANITY_CHECK=1
      SKIP_PARTITION_MOUNT_CHECK=1
      SKIP_VFAT_CHECK=1
      ;;
    --skip-archiso-check) SKIP_ARCHISO_CHECK=1 ;;
    --skip-ext4-check) SKIP_EXT4_CHECK=1 ;;
    --skip-mnt-check) SKIP_MNT_CHECK=1 ;;
    --skip-mounted-check) SKIP_MOUNTED_CHECK=1 ;;
    --skip-partition-mount-check) SKIP_PARTITION_MOUNT_CHECK=1 ;;
    --skip-sanity-check) SKIP_SANITY_CHECK=1 ;;
    --skip-vfat-check) SKIP_VFAT_CHECK=1 ;;
    --skip-welcome) SKIP_WELCOME=1 ;;
    # -V | --version )
    #   echo version
    #   exit
    #   ;;
    # -s | --string )
    #   shift; string=$1
    #   ;;
  esac; shift; done
  if [[ "$1" == '--' ]]; then shift; fi
}

# -------------------------------------------------------------------------------

# Quit and exit
quit:exit() {
  local cmd="./$(basename "$SCRIPT_FILE")"
  if [[ "$(pwd)" != "$(dirname "$SCRIPT_FILE")" ]]; then cmd="cd ; $cmd"; fi
  quit:exit_msg <<END
  You can proceed with the installation via:

      $cmd

  Feel free to edit it and see if everything is in order!
END
}

# Quit without message
quit:no_message() {
  clear
  exit 1
}

quit:exit_msg() {
  clear
  echo -e "\033[0;33m$INSTALLER_TITLE\033[0;m"
  echo -e "\033[0;33m$(printf "%${COLUMNS}s" | tr ' ' '-')\033[0;m"
  echo ""
  cat -
  echo ""
  exit 1
}

quit:disk_is_mounted() {
  local disk="$1"
  quit:exit_msg <<END
  The disk '$disk' seems to be mounted.

$(findmnt -o 'SOURCE,TARGET' | grep $disk | sed 's/^/      /g')

  Unmount it and run the installer again.

  (You can skip this check with '--skip-mounted-check', but this
  isn't recommended.)
END
}

quit:mnt_not_mounted() {
  quit:exit_msg <<END
  Please mount partitions manually into /mnt.

  This option is available if you would like full control over your
  filesystems. This is great for special setups like btrfs, encryption,
  and other needs.

  It doesn't seem like anything is mounted into /mnt yet. You may
  need to partition your drive, format the partitions, and mount
  them manually. An example would be:

      # (Just an example, don't follow this exactly!)
      mkfs.fat -F32 /dev/sda1
      mkfs.ext4 /dev/sda2
      mount /dev/sda1 /mnt/boot
      mount /dev/sda2 /mnt

  The Arch wiki has a guide:

      https://wiki.archlinux.org/index.php/installation_guide#Partition_the_disks

  Run the installer again after mounting into /mnt.

  (You can skip this check with '--skip-mnt-check'.)
END
}

quit:not_arch() {
  quit:exit_msg <<END
  Arch Linux is required.

  The Arch installer is meant to be run from the Arch Linux
  Live environment. You can download Arch Linux from the Arch
  Linux website.

      https://archlinux.org/downloads/

  Also check the Arch Installer website for more details.

      $INSTALLER_URL

  Also check the Arch Installer website for more details.
END
}

quit:wrong_hostname() {
  quit:exit_msg <<END
  You seem to be running the installer on something that
  isn't the Arch Linux live enviroment.
  
  The Arch installer is meant to be run from the Arch Linux
  Live environment. You can download Arch Linux from the Arch
  Linux website.

      https://archlinux.org/downloads/

  Also check the Arch Installer website for more details.

      $INSTALLER_URL

  (You can skip this check with '--skip-archiso-check'.)
END
}

quit:missing_util() {
  quit:exit_msg <<END
  '$1' is needed to install Arch Linux.

  The Arch installer is meant to be run from the Arch Linux
  Live environment. You can download Arch Linux from the Arch
  Linux website.

      https://archlinux.org/downloads/

  If you're trying to run this installer from within Arch Linux,
  you may need to install the '$2' package.

      sudo pacman -Syu $2
END
}

quit:not_efi() {
  quit:exit_msg <<END
  The Arch installer only supports EFI mode.
  
  There doesn't seem to be efivars present in your /sys.
  Your system is likely booted in legacy mode at the moment.
  Consider turning on UEFI mode in your BIOS settings.

  If you'd like to continue in Legacy mode, you may install
  Arch Linux manually:

      https://wiki.archlinux.org/Installation
END
}

# Show 'please run cfdisk' message and exit
quit:cfdisk() {
  quit:exit_msg <<END
  You can partition your disk by typing:

      cfdisk $1

  There are 2 partitions you need to create:

      1. An EFI partition
         (size '250M', Type 'EFI System')

      2. Linux partition
         (Type 'Linux file system')

  You'll want to format them afterwards:

      mkfs.fat -F32 /dev/sdXX
      mkfs.ext4 /dev/sdYY
      # (replace sdXX and sdYY with the actual partitions.)

  Run the installer again afterwards, and pick 'Choose partitions'
  when asked to partition your disk.
END
}

quit:already_mounted() {
  local dev="$1"
  local target="$2"
  quit:exit_msg <<END
  '$dev' seems to already be mounted to '$target'. The installer
  needs to mount this, so you may need to unmount it first.

      umount $dev
END
}

quit:format_efi_first() {
  quit:exit_msg <<END
  The EFI partition ($1) can't be mounted. You can try one of
  these things:

  - If it's mounted right now, unmount it and try again.
  - Format the partition first.

  The EFI partition seems like it's not mountable, and this
  is usually because it needs to be formatted first. You can use
  'mkfs' to format it:

      mkfs.fat -F32 $1

  Run the installer again afterwards.

  (You can skip this check with '--skip-partition-mount-check'.)
END
}

quit:format_root_first() {
  quit:exit_msg <<END
  The root partition ($1) can't be mounted. You can try one of
  these things:

  - If it's mounted right now, unmount it and try again.
  - Format the partition first.

  The root partition seems like it's not mountable, and this
  is usually because it needs to be formatted first. You can use
  'mkfs' to format it:

      mkfs.ext4 $1

  Run the installer again afterwards.

  (You can skip this check with '--skip-partition-mount-check'.)
END
}

quit:invalid_partition_selection() {
  quit:exit_msg <<END
  The Linux partition can't be the same as the EFI partition.
END
}

# Show 'no ext4 partition' error message and exit
quit:no_ext4() {
  quit:exit_msg <<END
  You don't seem to have an 'ext4' partition in '$disk' yet.
  You may need to partition your disk before continuing.

$(lsblk -o "NAME,FSTYPE,LABEL,SIZE" "$disk" | sed 's/^/      /g')

  Linux is usually installed into an ext4 partition. See the
  Arch wiki for details:

      https://wiki.archlinux.org/index.php/Installation_guide#Partition_the_disks

  (You can skip this check with '--skip-ext4-check'.)
END
}

# Show 'no vfat partition' error message and exit
quit:no_vfat() {
  clear
  echo "You don't seem to have an 'vfat' partition in '$disk' yet."
  echo "You may need to partition your disk before continuing."
  echo ""
  lsblk -o "NAME,FSTYPE,LABEL,SIZE" "$disk" | sed 's/^/    /g'
  echo ""
  echo "You will need an EFI partition. See the Arch wiki for details:"
  echo ""
  echo "    https://wiki.archlinux.org/index.php/EFI_system_partition"
  echo ""
  echo "Read the guide above, partition your disk with 'cfdisk' and run"
  echo "the installer again."
  echo ""
  echo "(You can skip this check with '--skip-vfat-check'.)"
  echo ""
  exit 1
}

# -------------------------------------------------------------------------------

disk:show_mnt_warning() {
  message=""
  message+="Please review the installation strategy:"
  message+="\n\Z1───────────────────────────────────────────────────────────────────\Zn"

  message+="\n\n\Zb\Z2No disk operations\Zn\n"
  message+="No partition tables will be edited. No partitions will be (re)formatted."

  message+="\n\n\Zb\Z2No boot loader will be installed\Zn\n"
  message+="You will need to install a boot loader yourself (eg, GRUB)."

  message+="\n\n\Zb\Z2Install Arch Linux into /mnt\Zn\n"
  message+="Arch Linux will be installed into whatever disk is mounted in \Zb/mnt\Zn at the moment."

  message+="\n"
  message+="\n\Z1───────────────────────────────────────────────────────────────────\Zn"
  message+="\nPress \ZbNext\Zn and we'll continue configuring your installation, or \Zbctrl-c\Zn to exit."

  $DIALOG "${DIALOG_OPTS[@]}" \
    --colors \
    --title " Review " \
    --ok-label "Next" \
    --msgbox "$message" \
    20 $WIDTH_MD \
    3>&1 1>&2 2>&3
}

# -------------------------------------------------------------------------------

# Return 0 if we're root, 1 otherwise
util:is_root() {
  [[ "$(id -u)" == "0" ]]
}

# Run something as a superuser
util:sudo() {
  local cmd="$1"
  if util:is_root; then
    $cmd
  elif which sudo &>/dev/null; then
    sudo $cmd
  else
    su -c "$cmd"
  fi
}

# Dev helpers: List available drives
util:list_drives() {
  # NAME="sda" SIZE="883GB"
  lsblk -I 8 -o "NAME,SIZE" -P -d
}

# Dev helpers: List available partitions
util:list_partitions() {
  disk="$1"
  # NAME="sda1" SIZE="883GB"
  lsblk -I 8 -o "NAME,SIZE,TYPE,FSTYPE,LABEL" -P \
    | grep 'TYPE="part"' \
    | grep "$(basename $disk)"
}

# "en_US.UTF-8 UTF-8" -> "en_US.UTF-8"
util:get_primary_locale() {
  local str="${PRIMARY_LOCALE[0]}"
  echo "${str% *}"
}

util:is_mnt_mounted() {
  if [[ "$SKIP_MNT_CHECK" == 1 ]]; then return; fi

  # Grep returns non-zero if it's not found
  findmnt '/mnt' | grep '/mnt' &>/dev/null
}

util:partition_info() {
  local partition="$1"
  NAME=""
  eval $(lsblk -o "NAME,SIZE,TYPE,FSTYPE,LABEL" -P \
    | grep 'TYPE="part"' \
    | grep "$(basename $partition)")

  if [[ -n "$NAME" ]]; then
    echo "$partition ($SIZE $FSTYPE)"
  else
    echo "$partition (new)"
  fi
}

# Random utils
utils:arch_logo() {
  echo "
            .
           /#\\
          /###\\                     #     | .   __
         /#^###\\       a#e #%' a#'e 6##%  | | |'  | |   | \\ /
        /##P^q##\\    .oOo# #   #    #  #  | | |   | |   |  X
       /##(   )##\\   %OoO# #   %#e' #  #  | | |   | '._.| / \\
      /###P   q##^\\
     /P^         ^q\\
  "
}

# Escape text
esc() {
  printf "%q" "$1"
}

# -------------------------------------------------------------------------------

# Lets go!
set_defaults
set_constants
main "$@"
