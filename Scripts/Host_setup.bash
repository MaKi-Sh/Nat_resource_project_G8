#!/bin/bash
printf "This is the setup config for a Heterogenous Beowulf cluster for host server \n"
printf "Here are the steps that we will take for setting up this server \n 1. Presetup \n 2. Shared File System \n 3. SSH setup \n 4. OpenMPI setup \n 5. Test run\n"
printf "Presetup \n 1. Package updates \n 2. User Creation\n"
read -p "Computer type (Master/Worker/NFS): " computer
if [ "$computer" = "Master" ]; then
	read -p "Is computer also NFS (Y/n): " is_main_NFS
fi


COMPOSTYPE=$(case "$OSTYPE" in
	darwin*)  echo "macOS";;
	linux*)   echo "Linux";;
	msys*)    echo "Windows";;
	cygwin*)  echo "Windows";;
	*)        echo "Unknown";;
esac)
echo "Detected OS: $COMPOSTYPE"

distro="unknown"
if [ "$COMPOSTYPE" = "Linux" ]; then
	if [ -f /etc/os-release ]; then
		. /etc/os-release
		distro=$ID  # returns 'debian', 'ubuntu', 'fedora', etc.
	fi
	echo "Detected Distro: $distro"
fi

OMPI_VERSION=5.0.7
OMPI_PREFIX=/usr/local
BUILD_DIR=/tmp/ompi-build

# ---------------------------------------------------------------------------
# 1. Install NFS client + openMPI build dependencies per distro / OS
# ---------------------------------------------------------------------------
if [ "$COMPOSTYPE" = "Linux" ]; then
	case "$distro" in
		debian|ubuntu|linuxmint|mx|kali|antix|pop|elementary|raspbian|devuan)
			sudo apt update
			sudo apt install -y nfs-common build-essential gcc g++ gfortran \
				make wget tar perl m4 autoconf automake libtool flex
			;;
		arch|manjaro|endeavouros|artix|garuda)
			sudo pacman -Syu --noconfirm
			sudo pacman -S --noconfirm --needed nfs-utils base-devel gcc \
				gcc-fortran make wget tar perl m4 autoconf automake libtool flex
			;;
		fedora|rhel|centos|rocky|almalinux|ol|amzn)
			sudo dnf install -y nfs-utils gcc gcc-c++ gcc-gfortran make wget \
				tar perl m4 autoconf automake libtool flex
			sudo dnf groupinstall -y "Development Tools"
			;;
		opensuse|opensuse-leap|opensuse-tumbleweed|sles|suse)
			sudo zypper refresh
			sudo zypper install -y nfs-client gcc gcc-c++ gcc-fortran make \
				wget tar perl m4 autoconf automake libtool flex
			sudo zypper install -y -t pattern devel_basis
			;;
		alpine)
			sudo apk update
			sudo apk add nfs-utils build-base gcc g++ gfortran make wget tar \
				perl m4 autoconf automake libtool flex linux-headers
			;;
		gentoo)
			sudo emerge --sync
			sudo emerge -av net-fs/nfs-utils sys-devel/gcc sys-devel/make \
				net-misc/wget app-arch/tar dev-lang/perl sys-devel/m4 \
				sys-devel/autoconf sys-devel/automake sys-devel/libtool \
				sys-devel/flex
			;;
		void)
			sudo xbps-install -Sy nfs-utils base-devel gcc gcc-fortran make \
				wget tar perl m4 autoconf automake libtool flex
			;;
		slackware)
			sudo slackpkg update
			sudo slackpkg install nfs-utils gcc gcc-g++ gcc-gfortran make \
				wget tar perl m4 autoconf automake libtool flex
			;;
		*)
			echo "Unsupported / unknown Linux distro: '$distro'"
			echo "Install manually: nfs client utilities + a C/C++/Fortran toolchain + wget + tar"
			;;
	esac
elif [ "$COMPOSTYPE" = "macOS" ]; then
	if ! command -v brew >/dev/null 2>&1; then
		/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
	fi
	brew update
	brew install gcc make wget autoconf automake libtool m4 perl flex
	# macOS ships with an NFS client; nothing extra to install.
elif [ "$COMPOSTYPE" = "Windows" ]; then
	# msys2 / cygwin path
	pacman -Syu --noconfirm
	pacman -S --noconfirm --needed base-devel mingw-w64-x86_64-toolchain \
		mingw-w64-x86_64-gcc mingw-w64-x86_64-gcc-fortran make wget tar \
		perl m4 autoconf automake libtool flex
	echo "Note: enable Windows 'Services for NFS' or 'Client for NFS' feature for the shared filesystem step."
else
	echo "Unsupported OS: $COMPOSTYPE — install build toolchain + nfs client manually before continuing."
fi

# ---------------------------------------------------------------------------
# 2. Build openMPI ${OMPI_VERSION} from source (every host gets the same version)
# ---------------------------------------------------------------------------
echo "Building openMPI ${OMPI_VERSION} from source into ${OMPI_PREFIX}..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || exit 1

if [ ! -f "openmpi-${OMPI_VERSION}.tar.gz" ]; then
	wget "https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-${OMPI_VERSION}.tar.gz"
fi

tar -xzf "openmpi-${OMPI_VERSION}.tar.gz" || exit 1
cd "openmpi-${OMPI_VERSION}" || exit 1

JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
./configure --prefix="$OMPI_PREFIX" || exit 1
make -j"$JOBS" || exit 1
sudo make install || exit 1

if command -v ldconfig >/dev/null 2>&1; then
	sudo ldconfig
fi

echo "openMPI ${OMPI_VERSION} installed."
"${OMPI_PREFIX}/bin/mpirun" --version

# ---------------------------------------------------------------------------
# 3. Device rename (hostname) — lower-level per OS/distro
# ---------------------------------------------------------------------------
read -p "Desired device name (MUST BE UNIQUE): " device_name

if [ "$COMPOSTYPE" = "Linux" ]; then
	# /etc/hostname is the canonical persistent file on virtually every Linux
	echo "$device_name" | sudo tee /etc/hostname >/dev/null
	# Apply at runtime (no reboot required)
	sudo hostname "$device_name"

	# Distro-specific persistent config in addition to /etc/hostname
	case "$distro" in
		alpine|gentoo|artix|devuan)
			# OpenRC systems also read /etc/conf.d/hostname
			if [ -d /etc/conf.d ]; then
				echo "hostname=\"$device_name\"" | sudo tee /etc/conf.d/hostname >/dev/null
			fi
			;;
		slackware)
			# Slackware uses /etc/HOSTNAME
			echo "$device_name" | sudo tee /etc/HOSTNAME >/dev/null
			;;
	esac

	# Update /etc/hosts so the new name resolves locally
	if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
		sudo sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$device_name/" /etc/hosts
	else
		echo -e "127.0.1.1\t$device_name" | sudo tee -a /etc/hosts >/dev/null
	fi
elif [ "$COMPOSTYPE" = "macOS" ]; then
	sudo scutil --set HostName "$device_name"
	sudo scutil --set ComputerName "$device_name"
	sudo scutil --set LocalHostName "$device_name"
	dscacheutil -flushcache 2>/dev/null || true
elif [ "$COMPOSTYPE" = "Windows" ]; then
	# msys2 / cygwin path — invoke Windows native rename
	powershell.exe -Command "Rename-Computer -NewName '$device_name' -Force" || \
		cmd.exe /c "wmic computersystem where name=\"%COMPUTERNAME%\" call rename name=\"$device_name\""
	echo "Reboot required for hostname change to fully apply on Windows."
fi
echo "Hostname set to: $device_name"

# ---------------------------------------------------------------------------
# 4. User creation — lower-level per OS/distro
# Default is 'mpiuser' and MUST be identical across master + all workers.
# ---------------------------------------------------------------------------
echo "Creating new user, name is mpiuser"
username="mpiuser"

if [ "$COMPOSTYPE" = "Linux" ]; then
	case "$distro" in
		alpine)
			# Alpine ships BusyBox adduser (different flags than shadow-utils)
			sudo adduser -D -s /bin/sh "$username"
			sudo passwd "$username"
			;;
		*)
			# useradd is the low-level shadow-utils command — present on
			# debian/ubuntu/arch/fedora/rhel/suse/void/gentoo/slackware.
			sudo useradd -m -s /bin/bash -U "$username"
			sudo passwd "$username"
			;;
	esac
elif [ "$COMPOSTYPE" = "macOS" ]; then
	# Use sysadminctl (10.13+); fall back to dscl for older systems.
	if command -v sysadminctl >/dev/null 2>&1; then
		read -s -p "Password for $username: " userpass; echo
		sudo sysadminctl -addUser "$username" -fullName "$username" -password "$userpass"
		unset userpass
	else
		NEXT_UID=$(($(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1) + 1))
		sudo dscl . -create "/Users/$username"
		sudo dscl . -create "/Users/$username" UserShell /bin/bash
		sudo dscl . -create "/Users/$username" RealName "$username"
		sudo dscl . -create "/Users/$username" UniqueID "$NEXT_UID"
		sudo dscl . -create "/Users/$username" PrimaryGroupID 20
		sudo dscl . -create "/Users/$username" NFSHomeDirectory "/Users/$username"
		sudo passwd "$username"
	fi
elif [ "$COMPOSTYPE" = "Windows" ]; then
	# msys2/cygwin — create a real Windows account
	net user "$username" /add
else
	echo "Unsupported OS for automatic user creation: $COMPOSTYPE"
	echo "Create user '$username' manually before continuing."
fi



echo "Password created is equivalent to username if needed"

# ---------------------------------------------------------------------------
# 5. Shared File System (NFS) — server or client setup, cross-OS / cross-distro
# ---------------------------------------------------------------------------
printf "Shared File System\n 1. NFS master (server) setup\n 2. NFS client setup\n"

# Install NFS server package(s) per distro / OS
install_nfs_server() {
	if [ "$COMPOSTYPE" = "Linux" ]; then
		case "$distro" in
			debian|ubuntu|linuxmint|mx|kali|antix|pop|elementary|raspbian|devuan)
				sudo apt install -y nfs-kernel-server ;;
			arch|manjaro|endeavouros|artix|garuda)
				sudo pacman -S --noconfirm --needed nfs-utils ;;
			fedora|rhel|centos|rocky|almalinux|ol|amzn)
				sudo dnf install -y nfs-utils ;;
			opensuse|opensuse-leap|opensuse-tumbleweed|sles|suse)
				sudo zypper install -y nfs-kernel-server ;;
			alpine)
				sudo apk add nfs-utils ;;
			gentoo)
				sudo emerge -av net-fs/nfs-utils ;;
			void)
				sudo xbps-install -Sy nfs-utils ;;
			slackware)
				sudo slackpkg install nfs-utils ;;
			*)
				echo "Install NFS server package manually for distro '$distro'." ;;
		esac
	elif [ "$COMPOSTYPE" = "Windows" ]; then
		powershell.exe -Command "Install-WindowsFeature FS-NFS-Service -IncludeManagementTools" 2>/dev/null || \
			echo "Enable 'Services for NFS' / 'Server for NFS' Windows feature manually."
	fi
	# macOS ships with nfsd built-in — nothing to install.
}

# Start / enable NFS server per init system
start_nfs_server() {
	if [ "$COMPOSTYPE" = "Linux" ]; then
		case "$distro" in
			debian|ubuntu|linuxmint|mx|kali|pop|elementary|raspbian)
				sudo systemctl enable --now nfs-kernel-server ;;
			alpine)
				sudo rc-update add nfs default
				sudo rc-service nfs restart ;;
			artix|gentoo|devuan|antix)
				sudo rc-update add nfs default 2>/dev/null || true
				sudo rc-service nfs restart 2>/dev/null || \
					sudo rc-service nfs-server restart ;;
			void)
				sudo ln -sf /etc/sv/nfs-server /var/service/ 2>/dev/null || true
				sudo sv restart nfs-server 2>/dev/null || true ;;
			slackware)
				sudo /etc/rc.d/rc.nfsd restart ;;
			*)
				# systemd-based: arch, fedora, rhel, opensuse, ...
				sudo systemctl enable --now nfs-server 2>/dev/null || \
					sudo systemctl enable --now nfs 2>/dev/null || \
					sudo systemctl restart nfs-server ;;
		esac
	elif [ "$COMPOSTYPE" = "macOS" ]; then
		sudo nfsd enable 2>/dev/null || true
		sudo nfsd restart
	elif [ "$COMPOSTYPE" = "Windows" ]; then
		powershell.exe -Command "Set-Service -Name NfsService -StartupType Automatic; Start-Service -Name NfsService" 2>/dev/null || \
			echo "Start the 'Server for NFS' service manually."
	fi
}

# Detect 'nobody' group name (differs across distros)
nobody_group() {
	for g in nogroup nobody nfsnobody; do
		if getent group "$g" >/dev/null 2>&1; then
			echo "$g"
			return
		fi
	done
	echo "nobody"
}

if [ "$computer" = "NFS" ] || [[ "$is_main_NFS" =~ ^[Yy]$ ]]; then
	install_nfs_server

	read -p "Please input path to server NFS directory: " NFSPATH
	sudo mkdir -p "$NFSPATH"

	if [ "$COMPOSTYPE" = "Linux" ]; then
		NOBODY_GRP=$(nobody_group)
		sudo chown nobody:"$NOBODY_GRP" "$NFSPATH"
	elif [ "$COMPOSTYPE" = "macOS" ]; then
		sudo chown nobody:staff "$NFSPATH"
	fi
	sudo chmod 777 "$NFSPATH"

	EXPORTS_FILE="/etc/exports"
	echo "Enter client IP addresses (or CIDR ranges). Type 'Finished' or leave blank to stop."
	while true; do
		read -p "Client IP address: " IPADDRESS
		if [ -z "$IPADDRESS" ] || [ "$IPADDRESS" = "Finished" ]; then
			break
		fi

		if [ "$COMPOSTYPE" = "macOS" ]; then
			EXPORT_LINE="$NFSPATH -alldirs -mapall=nobody -network $IPADDRESS -mask 255.255.255.255"
		else
			EXPORT_LINE="$NFSPATH $IPADDRESS(rw,sync,no_subtree_check,no_root_squash)"
		fi

		if ! sudo grep -qF -- "$EXPORT_LINE" "$EXPORTS_FILE" 2>/dev/null; then
			echo "$EXPORT_LINE" | sudo tee -a "$EXPORTS_FILE" >/dev/null
		fi
	done

	if [ "$COMPOSTYPE" = "Linux" ]; then
		sudo exportfs -ra
	elif [ "$COMPOSTYPE" = "macOS" ]; then
		sudo nfsd update
	fi

	start_nfs_server
	echo "NFS server setup complete. Exporting: $NFSPATH"
else
	# Client setup — NFS client utilities were installed in step 1 on Linux/macOS.
	if [ "$COMPOSTYPE" = "Windows" ]; then
		powershell.exe -Command "Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly,ClientForNFS-Infrastructure -All -NoRestart" 2>/dev/null || \
			echo "Enable 'Services for NFS' / 'Client for NFS' Windows feature manually."
	fi

	read -p "Please input local mount point (client NFS directory): " NFSPATH
	read -p "Please input path to server NFS directory: " SERVERPATH
	read -p "Please input server IP: " SERVERIP

	sudo mkdir -p "$NFSPATH"

	if [ "$COMPOSTYPE" = "Linux" ] || [ "$COMPOSTYPE" = "macOS" ]; then
		sudo mount -t nfs "$SERVERIP:$SERVERPATH" "$NFSPATH"
		if [ "$COMPOSTYPE" = "Linux" ]; then
			FSTAB_ENTRY="$SERVERIP:$SERVERPATH $NFSPATH nfs defaults,_netdev 0 0"
			if ! grep -qF -- "$FSTAB_ENTRY" /etc/fstab; then
				echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab >/dev/null
			fi
		fi
	elif [ "$COMPOSTYPE" = "Windows" ]; then
		echo "Run (in cmd as admin): mount -o anon \\\\${SERVERIP}\\${SERVERPATH} ${NFSPATH}"
	fi

	echo "NFS client mount complete: $SERVERIP:$SERVERPATH -> $NFSPATH"
fi



# ---------------------------------------------------------------------------
# 6. Passwordless SSH — install/enable sshd on every host, generate a keypair
#    as $username, then on the master push the pubkey to each worker.
# ---------------------------------------------------------------------------
printf "SSH Setup\n 1. Install + start sshd\n 2. Generate SSH key as %s\n 3. Push key to workers (master only)\n" "$username"

# Install OpenSSH server + client per distro / OS
install_ssh_server() {
	if [ "$COMPOSTYPE" = "Linux" ]; then
		case "$distro" in
			debian|ubuntu|linuxmint|mx|kali|antix|pop|elementary|raspbian|devuan)
				sudo apt install -y openssh-server openssh-client ;;
			arch|manjaro|endeavouros|artix|garuda)
				sudo pacman -S --noconfirm --needed openssh ;;
			fedora|rhel|centos|rocky|almalinux|ol|amzn)
				sudo dnf install -y openssh-server openssh-clients ;;
			opensuse|opensuse-leap|opensuse-tumbleweed|sles|suse)
				sudo zypper install -y openssh ;;
			alpine)
				sudo apk add openssh openssh-client ;;
			gentoo)
				sudo emerge -av net-misc/openssh ;;
			void)
				sudo xbps-install -Sy openssh ;;
			slackware)
				sudo slackpkg install openssh ;;
			*)
				echo "Install openssh-server manually for distro '$distro'." ;;
		esac
	elif [ "$COMPOSTYPE" = "macOS" ]; then
		# Built-in OpenSSH; enable Remote Login.
		sudo systemsetup -setremotelogin on 2>/dev/null || true
	elif [ "$COMPOSTYPE" = "Windows" ]; then
		powershell.exe -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" 2>/dev/null || \
			echo "Install OpenSSH Server / Client capability manually."
	fi
}

# Enable + start sshd per init system
start_ssh_server() {
	if [ "$COMPOSTYPE" = "Linux" ]; then
		case "$distro" in
			debian|ubuntu|linuxmint|mx|kali|pop|elementary|raspbian)
				sudo systemctl enable --now ssh 2>/dev/null || \
					sudo systemctl enable --now sshd ;;
			alpine)
				sudo rc-update add sshd default
				sudo rc-service sshd restart ;;
			artix|gentoo|devuan|antix)
				sudo rc-update add sshd default 2>/dev/null || true
				sudo rc-service sshd restart ;;
			void)
				sudo ln -sf /etc/sv/sshd /var/service/ 2>/dev/null || true
				sudo sv restart sshd 2>/dev/null || true ;;
			slackware)
				sudo chmod +x /etc/rc.d/rc.sshd 2>/dev/null || true
				sudo /etc/rc.d/rc.sshd restart ;;
			*)
				# systemd: arch, fedora, rhel, opensuse, ...
				sudo systemctl enable --now sshd 2>/dev/null || \
					sudo systemctl enable --now ssh ;;
		esac
	elif [ "$COMPOSTYPE" = "Windows" ]; then
		powershell.exe -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd" 2>/dev/null || \
			echo "Start the sshd service manually."
	fi
	# macOS: already enabled via systemsetup above.
}

install_ssh_server
start_ssh_server

# Resolve home directory for $username (cross-OS)
if [ "$COMPOSTYPE" = "macOS" ]; then
	USER_HOME=$(dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null | awk -F': ' '{print $2}')
elif command -v getent >/dev/null 2>&1; then
	USER_HOME=$(getent passwd "$username" | cut -d: -f6)
fi
[ -z "$USER_HOME" ] && USER_HOME=$(eval echo "~$username")

KEYFILE="$USER_HOME/.ssh/id_ed25519"

# Generate the keypair (as $username so ownership is correct). Passphraseless
# because Beowulf/MPI launches require non-interactive auth.
if [ "$COMPOSTYPE" = "Windows" ]; then
	mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
	if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
		ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
	fi
	KEYFILE="$HOME/.ssh/id_ed25519"
else
	sudo -u "$username" mkdir -p "$USER_HOME/.ssh"
	sudo -u "$username" chmod 700 "$USER_HOME/.ssh"
	if ! sudo test -f "$KEYFILE"; then
		sudo -H -u "$username" ssh-keygen -t ed25519 -N "" -f "$KEYFILE"
	fi
fi

# Master: push pubkey to each worker so $username can ssh in passwordlessly
if [ "$computer" = "Master" ]; then
	echo "Enter worker IP addresses one at a time. Type 'Finished' or leave blank to stop."
	while true; do
		read -p "Worker IP address: " IPADDRESS
		if [ -z "$IPADDRESS" ] || [ "$IPADDRESS" = "Finished" ]; then
			break
		fi

		if command -v ssh-copy-id >/dev/null 2>&1; then
			if [ "$COMPOSTYPE" = "Windows" ]; then
				ssh-copy-id "$username@$IPADDRESS"
			else
				sudo -H -u "$username" ssh-copy-id "$username@$IPADDRESS"
			fi
		else
			# Fallback for systems without ssh-copy-id (e.g. native Windows OpenSSH)
			PUBKEY=$(sudo cat "${KEYFILE}.pub" 2>/dev/null || cat "${KEYFILE}.pub")
			ssh "$username@$IPADDRESS" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
		fi
	done
fi

echo "SSH setup complete."

# ---------------------------------------------------------------------------
# 7. OpenMPI hostfile + test run — master only
# ---------------------------------------------------------------------------

# Make sure git is available (some distros' build-tool packages don't include it)
ensure_git() {
	command -v git >/dev/null 2>&1 && return
	if [ "$COMPOSTYPE" = "Linux" ]; then
		case "$distro" in
			debian|ubuntu|linuxmint|mx|kali|antix|pop|elementary|raspbian|devuan)
				sudo apt install -y git ;;
			arch|manjaro|endeavouros|artix|garuda)
				sudo pacman -S --noconfirm --needed git ;;
			fedora|rhel|centos|rocky|almalinux|ol|amzn)
				sudo dnf install -y git ;;
			opensuse|opensuse-leap|opensuse-tumbleweed|sles|suse)
				sudo zypper install -y git ;;
			alpine)
				sudo apk add git ;;
			gentoo)
				sudo emerge -av dev-vcs/git ;;
			void)
				sudo xbps-install -Sy git ;;
			slackware)
				sudo slackpkg install git ;;
			*)
				echo "Install git manually for distro '$distro'." ;;
		esac
	elif [ "$COMPOSTYPE" = "macOS" ]; then
		brew install git
	elif [ "$COMPOSTYPE" = "Windows" ]; then
		pacman -S --noconfirm --needed git
	fi
}

if [ "$computer" = "Master" ]; then
	ensure_git

	# Workspace: prefer the NFS share so workers see the same binary; otherwise
	# fall back to $username's home (workers must compile/copy separately then).
	if [ -n "$NFSPATH" ] && [ -d "$NFSPATH" ]; then
		WORK_DIR="$NFSPATH"
	else
		WORK_DIR="$USER_HOME"
	fi
	REPO_DIR="$WORK_DIR/Nat_resource_project_G8"
	HOSTFILE="$WORK_DIR/hostfile.txt"

	printf "OpenMPI hostfile setup\n"
	# Master goes in the hostfile too — use this host's CPU count.
	MASTER_SLOTS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
	echo "localhost slots=$MASTER_SLOTS" | sudo -u "$username" tee "$HOSTFILE" >/dev/null

	echo "Add worker entries to the MPI hostfile. Type 'Finished' or leave blank to stop."
	while true; do
		read -p "Worker IP address: " CLIENTIP
		if [ -z "$CLIENTIP" ] || [ "$CLIENTIP" = "Finished" ]; then
			break
		fi
		read -p "Slots (CPU cores) on $CLIENTIP [default: 4]: " SLOTS
		SLOTS="${SLOTS:-4}"
		echo "$CLIENTIP slots=$SLOTS" | sudo -u "$username" tee -a "$HOSTFILE" >/dev/null
	done

	# -----------------------------------------------------------------------
	# 8. Test run — clone repo, build the Mandelbrot demo, print run command
	# -----------------------------------------------------------------------
	REPO_URL="https://github.com/MaKi-Sh/Nat_resource_project_G8"
	if sudo -u "$username" test -d "$REPO_DIR/.git"; then
		sudo -u "$username" git -C "$REPO_DIR" pull --ff-only
	else
		sudo -u "$username" git clone "$REPO_URL" "$REPO_DIR"
	fi

	SRC="$REPO_DIR/Scripts/Mandelbrotsim.cpp"
	BIN="$REPO_DIR/Scripts/Mandelbrotsim"
	if sudo -u "$username" test -f "$SRC"; then
		sudo -H -u "$username" "${OMPI_PREFIX}/bin/mpicxx" -O3 "$SRC" -o "$BIN"
		echo "Built: $BIN"
	else
		echo "Source not found at $SRC — adjust path before compiling."
	fi

	TOTAL_SLOTS=$(awk '{ for (i=1;i<=NF;i++) if ($i ~ /^slots=/) { split($i,a,"="); s+=a[2] } } END { print s+0 }' "$HOSTFILE")
	[ "${TOTAL_SLOTS:-0}" -gt 0 ] 2>/dev/null || TOTAL_SLOTS="<N>"

	printf "\nRun the demo from the master as %s:\n" "$username"
	printf "  mpirun -np %s --hostfile %s %s\n" "$TOTAL_SLOTS" "$HOSTFILE" "$BIN"
	printf "Compile other programs with: mpicxx -O3 programname.cpp -o programname\n"
	if [ -z "$NFSPATH" ] || [ ! -d "$NFSPATH" ]; then
		printf "NOTE: NFS share not detected — every worker must have the binary at the SAME absolute path (%s) for mpirun to launch it.\n" "$BIN"
	fi
fi
