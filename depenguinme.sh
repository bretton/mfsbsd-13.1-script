#!/usr/bin/env bash
#
# depenguinme.sh

# please bump version on change
VERSION="v0.0.13"

# v0.0.1  2022-07-28  bretton depenguin.me
#  this is a proof of concept with parts to be further developed
#
# v0.0.2  2022-07-30  bretton depenguin.me
#  retrieve and insert ssh key
#
# v0.0.3  2022-07-31  bretton depenguin.me
#  use uefi.bin as bios to enable support of >2TB disks
#  use hardened mfsbsd image and copy in imported keys
#
# v0.0.4  2022-08-01  grembo depenguin.me
#  use more official packages
#  add options
#  some cleanup
#
# v0.0.5  2022-08-03 various artists
#
# v0.0.6  2022-08-10 bretton depenguin.me
#  Bump qemu memory in options from 1GB to 8GB so tmpfs is large
#  enough to download freebsd install files
#  Add note about sudo to root before install
#
# v0.0.7  2022-08-11 grembo depenguin.me
#  Only install dependencies if not found
#
# v0.0.8  2022-08-11 bretton depenguin.me
#  Remove unnecessary exported variables
#  migrate historical context info from script to changelog
#   2022-07-28
#   due to problems compiling static qemu binary from source we'll use
#   the one referenced in this post
#   https://forums.freebsd.org/threads/installing-freebsd-in-hetzner.85399/post-575119
#   Mirrors
#   - https://support.org.ua/Soft/vKVM/orig/vkvm.tar.gz
#   - https://cdn.rodney.io/content/blog/files/vkvm.tar.gz
#   - https://abcvg.ovh/uploads/need/vkvm-latest.tar.gz
#   - https://depenguin.me/files/vkvm.tar.gz
#   For bios supporting >2TB disks and static qemu above
#   - https://support.org.ua/Soft/vKVM/orig/uefi.tar.gz
#   - https://depenguin.me/files/uefi.tar.gz
#
# v0.0.9  2022-08-13 bretton depenguin.me
#  README updates, switch to unattended bsdinstall process over zfsinstall
#
# v0.0.10 2022-08-23 grembo depenguin.me
#  Add IPv6 support, add dependency for kvm-ok, enable qemu monitor socket
#
# v0.0.11 2023-04-06 bretton depenguin.me
#  re-do 4 disk solution
#
# v0.0.12 2023-09-08 bretton depenguin.me
#  Include package ovmf in DEPS
#
# v0.0.13 2023-xx-xx bretton depenguin.me
#  Four disk version 
#


# this script must be run as root
if [ "$EUID" -ne 0 ]; then
	echo "Please run this script as root. Recovery console should be root user"
	exit
fi

set -eo pipefail

exit_error() {
	echo "$*" 1>&2
	exit 1;
}

print_version() {
	echo "depenguinme $VERSION"
}

is_url() {
	[[ "$1" =~ ^(http|https|ftp):// ]]
}

DEFAULT_QEMU_RAM=8G
QEMU_RAM=$DEFAULT_QEMU_RAM
REQUIRE_SSHKEY=YES
DAEMONIZE=NO
USE_IPV6=NO
MFSBSDISO="https://depenguin.me/files/mfsbsd-13.1-RELEASE-amd64.iso"
DEPS=(
  "mkisofs:mkisofs"
  "qemu-system-x86_64:qemu-system-x86"
  "kvm-ok:cpu-checker"
  "ovmf:ovmf"
  )  # binary:package

usage() {
	cat <<-EOF
	Usage: $(basename "${BASH_SOURCE[0]}") [-hvd] [-m url] [-r ram] authorized_keys ...

	  -h Show help
	  -v Show version
	  -d daemonize
	  -m : URL of mfsbsd image (defaults to image on https://depenguin.me)
	       When specifying an non-default mfsbsd image, authorized_keys becomes
	       optional.
	  -r : Memory available to the VM (defaults to $DEFAULT_QEMU_RAM).
	       Supported suffixes are 'M' for MiB and 'G' for GiB.

	  authorized_keys can be file or a URL to a file which contains ssh public
	  keys for accessing the mfsbsd user within the vm. It can be used
	  multiple times.
	EOF
}

while getopts "hvdm:r:" flags; do
	case "${flags}" in
	h)
		usage
		exit 0
		;;
	v)
		print_version
		exit 0
		;;
	d)
		DAEMONIZE=YES
		;;
	m)
		MFSBSDISO="${OPTARG}"
		REQUIRE_SSHKEY=NO
		;;
	r)
		QEMU_RAM="${OPTARG}"
		;;
	*)
		exit_error "$(usage)"
		;;
	esac
done
shift "$((OPTIND-1))"

if [ "$#" -eq 0 ] && [ "$REQUIRE_SSHKEY" = "YES" ]; then
	exit_error "$(usage)"
fi

authkeys=()

while [ "$#" -gt 0 ]; do
	if is_url "$1"; then
		authkeys+=("$1")
	else
		authkeys+=("$(realpath "$1")")
	fi
	shift
done

# determine network stack
if ! ip route get 1 >/dev/null 2>&1; then
	USE_IPV6="YES"
	echo "No IPv4 public IP found, Using IPv6"
	DEPS+=("socat:socat")
fi

# determine required packages
install_pkgs=()
for cmd_pkg in "${DEPS[@]}"; do
	cmd=$(echo "$cmd_pkg" | cut -d : -f 1)
	pkg=$(echo "$cmd_pkg" | cut -d : -f 2)
	if ! command -v "$cmd" &>/dev/null; then
		install_pkgs+=("$pkg")
	fi
done

# install required packages
if [ ${#install_pkgs[@]} -gt 0 ]; then
	apt-get update
	for pkg in "${install_pkgs[@]}"; do
		apt-get install -y "$pkg"
	done
fi

# vars, do not adjust unless you know what you're doing for this script
QEMUBASE="/tmp/depenguinme"
USENVME=0
if [ "$USE_IPV6" = "YES" ]; then
	MYPRIMARYIP=$(ip -6 addr | grep -i global | awk '{ print $2 }' |\
	  cut -d / -f1 | head -n1)
else
	MYPRIMARYIP=$(ip route get 1 2>/dev/null | awk '{print $(NF-2);exit}')
fi
MYVNC="127.0.0.1:1"
MYVGA="std"   # could be qxl but not enabled for the static-qemu binary
MYBIOS="/usr/share/ovmf/OVMF.fd"
MYKEYMAP="en-us"
MYLOG="${QEMUBASE}/qemu-depenguin.log"
MYISOAUTH="${QEMUBASE}/myiso.iso"
MFSBSDFILE="${QEMUBASE}/$(echo "$MFSBSDISO" | sha256sum | awk '{print $1}').iso"

mkdir -p "$QEMUBASE"

###
# Custom build mfsbsd file
QEMUBIN=$(which qemu-system-x86_64 ||\
  exit_error "Could not find qemu-system-x86_64")

# change directory to /tmp to continue
cd "${QEMUBASE}" || exit_error "Could not cd to $QEMUBASE"

# setup or retrieve authorised keys
: >COPYKEY.pub

for key in "${authkeys[@]}"; do
	if is_url "$key"; then
		wget -qO - "$key" >>COPYKEY.pub
	else
		cat "$key" >>COPYKEY.pub
	fi
done

if [ "$REQUIRE_SSHKEY" = "YES" ]; then
	[ -s COPYKEY.pub ] || exit_error "Authorized key sources are empty"
fi

# temp solution to make iso with authorized_keys
mkdir -p "${QEMUBASE}"/myiso
if [ -f "${QEMUBASE}"/COPYKEY.pub ] && [ -d "${QEMUBASE}"/myiso ]; then
	cp -f COPYKEY.pub "${QEMUBASE}"/myiso/mfsbsd_authorized_keys
else
	exit_error "Error copying COPYKEY.pub to myiso/mfsbsd_authorized_keys"
fi

# create iso image with the public keys
if [ -f "${QEMUBASE}"/myiso/mfsbsd_authorized_keys ]; then
	/usr/bin/genisoimage -v -J -r -V MFSBSD_AUTHKEYS \
	  -o "${MYISOAUTH}" "${QEMUBASE}"/myiso/mfsbsd_authorized_keys
else
	exit_error "Missing myiso/mfsbsd_authorized_keys"
fi

# download mfsbsd image
wget -qc -O "${MFSBSDFILE}" "${MFSBSDISO}" || exit_error "Could not download mfsbsd image"

# Get a list of disks
# this includes sda* and nvme*
# lsblk -nd --exclude 7 --output NAME --ascii

# check if sda & sdb
echo "Searching sd[ab]"
set +e

# get a list of sd* disks, use grep inverse search
my_standard_disks=$(lsblk -nd --exclude 7 --output NAME --ascii | grep -v nvme)

if [ -n "$my_standard_disks" ]; then
    standard_disk_count=$(echo "$my_standard_disks" | wc -l)
    if [ "$standard_disk_count" -eq 1 ]; then
        checkdiskone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sda)
    elif [ "$standard_disk_count" -eq 2 ]; then
        checkdiskone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sda)
        notcdrom=$(lsblk |grep sdb |grep cdrom)
            if [ -z "${notcdrom}" ]; then
                checkdisktwo=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdb)
            else
                checkdisktwo=""
            fi
    elif [ "$standard_disk_count" -eq 3 ]; then
        checkdiskone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sda)
        notcdrom=$(lsblk |grep sdb |grep cdrom)
            if [ -z "${notcdrom}" ]; then
                checkdisktwo=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdb)
                checkdiskthree=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdc)
                checkdiskfour=""
            else
                checkdisktwo=""
                checkdiskthree=""
                checkdiskfour=""
            fi
    elif [ "$standard_disk_count" -eq 4 ]; then
        checkdiskone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sda)
        notcdrom=$(lsblk |grep sdb |grep cdrom)
            if [ -z "${notcdrom}" ]; then
                checkdisktwo=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdb)
                checkdiskthree=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdc)
                checkdiskfour=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdd)
            else
                checkdisktwo=""
                checkdiskthree=""
                checkdiskfour=""
            fi
    fi
else
    echo "Empty set for sd* disks"
fi
set -e

# check if sda & sdb
#echo "Searching sd[ab]"
#set +e
#checkdiskone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sda)
#notcdrom=$(lsblk |grep sdb |grep cdrom)
#if [ -z "${notcdrom}" ]; then
#	checkdisktwo=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdb)
#    checkdiskthree=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdc)
#    checkdiskfour=$(lsblk -nd --exclude 7 --output NAME --ascii |grep sdd)
#else
#    checkdisktwo=""
#    checkdiskthree=""
#    checkdiskfour=""
#fi

# TODO: This is setup but not used in the next NVME step, can be done?
# get a list of nvme* disks, use grep inverse search
#my_nvme_disks=$(lsblk -nd --exclude 7 --output NAME --ascii | grep -v sd)
#
#if [ -n "$my_nvme_disks" ]; then
#    nvme_disk_count=$(echo "$my_nvme_disks" | wc -l)
#else
#    echo "Empty set for nvme* disks"
#fi

# check for nvme, hetzner specific
set +e
echo "Searching nvme"
mycheck=$(which nvme)
if [ -n "${mycheck}" ]; then
	existsnvme=$(nvme list | grep -c "/dev/nvme")
	if [ "$existsnvme" -ge 2 ]; then
		checknvmeone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep nvme0n1)
		checknvmetwo=$(lsblk -nd --exclude 7 --output NAME --ascii |grep nvme1n1)
		USENVME=1
	elif [ "$existsnvme" -eq 1 ]; then
		checknvmeone=$(lsblk -nd --exclude 7 --output NAME --ascii |grep nvme0n1)
		USENVME=1
	elif [ -z "$existsnvme" ]; then
		USENVME=0
	fi
fi
set -e

disks=()

# start qemu-static with parameters
if [ "$USENVME" -eq 0 ]; then
	#if [ -n "$checkdiskone" ] && [ -n "$checkdisktwo" ]; then
	#	printf "\nNOTICE: using sda and sdb\n\n"
	#	disks=(
	#	  -drive "file=/dev/sda,format=raw" \
	#	  -drive "file=/dev/sdb,format=raw" \
	#	)
	#elif [ -n "$checkdiskone" ] && [ -z "$checkdisktwo" ]; then
	#	printf "\nNOTICE: using sda only\n\n"
	#	disks=(
	#	  -drive "file=/dev/sda,format=raw" \
	#	)
	#fi
    if [ -n "$checkdiskone" ] && [ -n "$checkdisktwo" ] && [ -z "$checkdiskthree" ] && [ -z "$checkdiskfour" ]; then
        printf "\nNOTICE: using sda and sdb\n\n"
        disks=(
          -drive "file=/dev/sda,format=raw" \
          -drive "file=/dev/sdb,format=raw" \
        )
    elif [ -n "$checkdiskone" ] && [ -z "$checkdisktwo" ] && [ -n "$checkdiskthree" ] && [ -z "$checkdiskfour" ]; then
        printf "\nNOTICE: using sda, sdb and sdc\n\n"
        disks=(
          -drive "file=/dev/sda,format=raw" \
          -drive "file=/dev/sdb,format=raw" \
          -drive "file=/dev/sdc,format=raw" \
        )
    elif [ -n "$checkdiskone" ] && [ -z "$checkdisktwo" ] && [ -n "$checkdiskthree" ] && [ -n "$checkdiskfour" ]; then
        printf "\nNOTICE: using sda, sdb, sdc and sdd\n\n"
        disks=(
          -drive "file=/dev/sda,format=raw" \
          -drive "file=/dev/sdb,format=raw" \
          -drive "file=/dev/sdc,format=raw" \
          -drive "file=/dev/sdd,format=raw" \
        )
    elif [ -n "$checkdiskone" ] && [ -z "$checkdisktwo" ] && [ -z "$checkdiskthree" ] && [ -z "$checkdiskfour" ]; then
        printf "\nNOTICE: using sda only\n\n"
        disks=(
          -drive "file=/dev/sda,format=raw" \
        )
    fi
elif [ "$USENVME" -eq 1 ]; then
	if [ -n "$checknvmeone" ] && [ -n "$checknvmetwo" ]; then
		printf "\nNOTICE: using nvme0 and nvme1\n\n"
		disks=(
		  -drive "file=/dev/nvme0n1,format=raw" \
		  -drive "file=/dev/nvme1n1,format=raw" \
		)
	elif [ -n "$checknvmeone" ] && [ -z "$checknvmetwo" ]; then
		printf "\nNOTICE: using nvme0 only\n\n"
		disks=(
		  -drive "file=/dev/nvme0n1,format=raw" \
		)
	fi
fi

if [ ${#disks[@]} -eq 0 ]; then
	exit_error "Could not find any disks"
fi

# arguments to qemu
qemu_args=(\
  -net nic \
  -net "user,hostfwd=tcp::1022-:22" \
  -m "$QEMU_RAM" \
  -rtc base=localtime \
  -M pc \
  -smp 1 \
  -bios "${MYBIOS}" \
  -vga "${MYVGA}" \
  -k "${MYKEYMAP}" \
  "${disks[@]}" \
  -cdrom "${MFSBSDFILE}" \
  -drive file="${MYISOAUTH},media=cdrom" \
  -boot once=d \
  -vnc "${MYVNC}" \
  -D "${MYLOG}"\
  -monitor "unix:/tmp/depenguinme/qemu-monitor-socket,server,nowait" \
)

if kvm-ok; then
	qemu_args+=(-enable-kvm -cpu host)
fi


if [ "$DAEMONIZE" = "YES" ]; then
	qemu_args+=(-daemonize)
fi

# check for qemu start in the background
(
	set +e
	sleep 2

	# let the system boot, yes we need this much time
	# at least 2 minutes with rc.local adjustments
	for c in {0..5}; do
		echo "Please wait, booting... $((30 - 5*c))s"
		sleep 5
	done
	echo "Waiting for sshd to become available..."

	# scan for keys
	while ! ssh-keyscan -p 1022 -T 5 127.0.0.1 2>/dev/null; do
		echo "Waiting for sshd to become available..."
		sleep 5;
	done

	# we should be able to ssh without a password now
	cat <<-EOF
	The system should ready to access with automatic login from a host with the associated private key!

	  ssh -p 1022 mfsbsd@${MYPRIMARYIP}

	If you have difficulty connecting due to ssh key exchange error. then WAIT 2 MINUTES and try again.
	SSH needs to come up correctly first.

	Change to root to continue install with 'sudo su -'.

	Run 'zfsinstall -h' for install options, or provision with ansible scripts that cover installation.

	Please report success or problems to us:
	https://github.com/depenguin-me/mfsbsd-13.1-script/issues

	$(print_version) on $(date "+%Y-%m-%d")

	EOF

	if [ "$USE_IPV6" = "YES" ]; then
		cat <<-EOF
		NOTE: You are using an IPv6 only system. To enable IPv6 inside of mfsBSD run

		        /root/enable_ipv6.sh

		EOF
	fi

	if [ "$DAEMONIZE" = "YES" ]; then
		echo "--- DEPENGUINME SCRIPT COMPLETE ---"
	else
		echo "Press CTRL-C to exit qemu"
	fi
)&
keyscan_pid=$!

if [ "$USE_IPV6" = "YES" ]; then
	set +e
	socat TCP6-LISTEN:1022,fork,bind="$MYPRIMARYIP" TCP4:127.0.0.1:1022 &
	socat_pid=$!
	set -e
fi

function finish {
	set +e
	if [ "$DAEMONIZE" != "YES" ]; then
		kill "$socat_pid" >/dev/null 2>&1
	fi
	kill "$keyscan_pid" >/dev/null 2>&1
	kill 0
}
trap finish EXIT

echo "Starting qemu..."
${QEMUBIN} "${qemu_args[@]}"

wait $keyscan_pid
