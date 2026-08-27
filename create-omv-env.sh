#!/bin/sh
set -e

SCRIPTDIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$SCRIPTDIR"

keepsudoalive() {
	# Keep sudo timestamp alive so we don't get timeouts
	# just because someone doesn't want to sit through a
	# package build that takes > $SUDO_TIMESTAMP_TIMEOUT
	# -v always prompts here after the ticket expires; NOPASSWD works for real commands
	sudo -n true
	(sleep 4m; keepsudoalive) &>/dev/null &
}

usage() {
	cat >&2 <<EOF
Usage: $0 [options] SET [SET...]

Options:
	-w		Wipe the target sysroot first
	-r PACKAGE	Resume at PACKAGE
	-t TARGET	rpm target (default: riscv64-linux)

A bare TARGET token (e.g. loongarch64-linux) is also accepted among
the positional arguments.

Sets are files in sets/ and may be combined, e.g.
	$0 core
	$0 os-image-builder
	$0 neovim
	$0 core os-image-builder neovim

Available sets:
EOF
	if [ -d "$SCRIPTDIR/sets" ]; then
		ls "$SCRIPTDIR/sets" | sed 's/^/	/' >&2
	fi
}

WIPE=false
RPMTARGET=riscv64-linux
RESUME=
while getopts "whr:t:" opt; do
	case $opt in
	w)
		# Wipe out previous root to make sure none of the script's
		# results are influenced by "leftovers"
		WIPE=true
		;;
	r)
		# Resume an aborted build process at the given package
		RESUME=$OPTARG
		;;
	t)
		RPMTARGET=$OPTARG
		;;
	h)
		usage
		exit 0
		;;
	*)
		usage
		exit 1
		;;
	esac
done
shift $((OPTIND-1))

SETS=
while [ $# -gt 0 ]; do
	case $1 in
	*/*)
		echo "Invalid set name: $1" >&2
		exit 1
		;;
	esac
	if [ -f "$SCRIPTDIR/sets/$1" ]; then
		already=
		for s in $SETS; do
			if [ "$s" = "$1" ]; then
				already=1
				break
			fi
		done
		if [ -z "$already" ]; then
			SETS="$SETS $1"
		fi
	else
		probe=$(rpm --target="$1" -E '%{_target_platform}' 2>/dev/null || true)
		if [ -n "$probe" ] && [ "$probe" != "%{_target_platform}" ]; then
			RPMTARGET=$1
		else
			echo "Unknown set or target: $1" >&2
			usage
			exit 1
		fi
	fi
	shift
done
SETS=${SETS# }
if [ -z "$SETS" ]; then
	echo "No set specified." >&2
	usage
	exit 1
fi

FULLTARGET=$(rpm --target=$RPMTARGET -E %{_target_platform})
if [ "$FULLTARGET" = "%{_target_platform}" ]; then
	cat >/dev/stderr <<EOF
Not a valid target platform. Please make sure the platform files
for the target $RPMTARGET exist in /usr/lib/rpm/platform and the
corresponding cross tools have been built.

The best way to do this is to update the rpm, binutils, gcc,
cmake and meson packages with $RPMTARGET added to the %targets
define already there.
EOF
	exit 1
fi

echo "Targeting $RPMTARGET = $FULLTARGET"
echo "Sets: $SETS"

keepsudoalive

# rpmbuild --load does not override /etc/rpm/macros.d. Install the
# tree copy so %%set_cross_env (config.sub refresh, sysroot env)
# is what --target builds actually run.
sudo cp -f "$SCRIPTDIR/macros.cross-pkgconfig" /etc/rpm/macros.d/macros.cross-pkgconfig
sudo cp -f "$SCRIPTDIR/macros.cross-pkgconfig" /etc/rpm/macros.cross-pkgconfig

if $WIPE; then
	rpm -qa |grep cross-${FULLTARGET} |xargs sudo dnf -y erase || :
	sudo rm -rf /usr/${FULLTARGET}
fi

# Host side dependencies. xbiff is actually needed (by mkcomposecache).
# zsh is needed for curl to detect where to install zsh autocompletions.
# elinks is needed by pam to generate man pages.
sudo dnf -y install task-devel texinfo asciidoc 'perl(Pod::Html)' 'perl(open)' nettle libtasn1-tools cmake 'pkgconfig(systemd)' 'pkgconfig(xkeyboard-config)' 'pkgconfig(wayland-protocols)' bpftool 'pkgconfig(fdisk)' 'pkgconfig(tss2-esys)' 'pkgconfig(libbpf)' 'pkgconfig(pwquality)' 'pkgconfig(libqrencode)' 'pkgconfig(libkmod)' 'pkgconfig(libmicrohttpd)' 'pkgconfig(liblz4)' 'pkgconfig(libseccomp)' cross-${FULLTARGET}-binutils cross-${FULLTARGET}-gcc cross-${FULLTARGET}-libc cross-${FULLTARGET}-kernel-headers console-setup glibc-i18ndata lzip gtk-doc luajit-lpeg luajit-mpack 'pkgconfig(dbus-1)' libmpc-devel publicsuffix-list slibtool x11-server-xvfb xbiff xkbcomp mkcomposecache x11-xtrans-devel scdoc 'perl(Time::Piece)' zsh doxygen graphviz python-pefile rst2man python-pyelftools meson 'python3.14dist(myst-parser)' groff flang python-sphinx python-sphinx-automodapi python-furo elinks docbook5-schemas docbook-style-xsl-ns xmlto bison make gettext libtool locales-extra-charsets po4a itstool appstream swig boost-build lib64girepository-devel

ARCH="$(echo $FULLTARGET |cut -d- -f1)"
case $ARCH in
arm*)
	ARCH=arm
	;;
i?86|pentium?|athlon)
	ARCH=i386
	;;
esac

LIBC="$(echo $FULLTARGET |cut -d- -f4)"
case $LIBC in
gnu*)
	LIBC=glibc
	;;
musl*)
	LIBC=musl
	;;
uclibc*|uClibc*)
	LIBC=uclibc
	;;
esac

[ -h /usr/$FULLTARGET/sys-root ] || sudo ln -sf . /usr/$FULLTARGET/sys-root

# Some notes for the build order (and reasons for packages you
# might not expect to see in a core package set):
# - systemd, expat -> dbus
# - dbus -> rpm, systemd
# - libtirpc, libnsl -> pam
# - libbpf, tmp2-tss, libidn2, cryptsetup, gnutls, libxkbcommon, glib2.0 -> systemd
# - gmp, libunistring, nettle, libtasn1, brotli, p11-kit -> gnutls
# - wayland -> libxkbcommon
# - libffi -> p11-kit
# - json-c, curl, openssl -> tpm2-tss
# - libssh -> curl
# - lksctp-tools -> openssl
# - libmicrohttpd -> elfutils (libelf) -> libbpf -> systemd
# - libidn2 -> systemd
# - libpng -> qrencode -> systemd
# - cracklib -> libpwquality -> systemd
# - x11-proto-devel -> libxau -> libxkbfile -> xkbcomp -> libxcb -> libx11 -> dbus
# Because of the way we package LLVM to avoid cyclic dependencies
# (Vulkan headers and friends inside SPIR-V), we also need half a
# GUI stack:
# - vulkan-headers, vulkan-loader -> LLVM
# - libXrender, libXext -> libXrandr -> vulkan-loader
# - x11-xtrans-devel is a dependency of libx11
# - x11-sgml-doctools is needed so X.Org packages find stylesheets
#   in the sysroot (PKG_CONFIG_SYSROOT_DIR prefixes host .pc paths)
# - libxau is a dependency of libxcb
#
# Anything in the list after llvm is there to fulfill runtime dependencies of the
# packages built before. If you want to build the minimal possible system, you can
# leave some of those out and remove a couple of subpackages.

ABF_DOWNLOADS=http://abf-downloads.openmandriva.org/
OMV_VERSION=cooker
PKGS=${ABF_DOWNLOADS}/${OMV_VERSION}/repository/x86_64/main/release/
curl -s -L $PKGS |grep '^<a' |cut -d'"' -f2 >PACKAGES

NEEDED=
for setname in $SETS; do
	echo "Loading set $setname"
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in
		''|'#'*)
			continue
			;;
		esac
		line=${line%%#*}
		for tok in $line; do
			case $tok in
			LIBC|LIBC:*)
				tok="$LIBC${tok#LIBC}"
				;;
			esac
			NEEDED="$NEEDED $tok"
		done
	done < "$SCRIPTDIR/sets/$setname"
done
NEEDED=${NEEDED# }
# Packages needed for the openmandriva/builder docker container
BUILDER_PACKAGES="mock git builder-c rpmdevtools python-pyyaml nosync python-magic"

# Match the first NEEDED token whose package name is $RESUME, even
# when that token carries rpmbuild flags (ncurses:-cplusplus) and
# even when the same package appears again later (pam:bootstrap then pam).
if [ -n "$RESUME" ]; then
	found=
	new=
	for tok in $NEEDED; do
		pkg="${tok%%:*}"
		if [ -n "$found" ] || [ "$pkg" = "$RESUME" ] || [ "$tok" = "$RESUME" ]; then
			found=1
			new="$new $tok"
		fi
	done
	if [ -z "$found" ]; then
		echo "Nothing to resume: '$RESUME' is not in the package list" >&2
		exit 1
	fi
	NEEDED=${new# }
fi

for i in $NEEDED; do
	PACKAGE="${i/:*}"
	if [ "$PACKAGE" != "cloud-utils" ] && [ "$PACKAGE" != "python-enchant" ] && grep -q "^${PACKAGE}-[0-9].*\.noarch\.rpm" PACKAGES; then
		# We can save some time on noarch packages...
		# cloud-utils is excepted from this because we need to build its subpackage growpart
		# python-enchant is excepted because the cooker noarch is an older
		# python and we need python%{pyver}dist(pyenchant)
		P=$(grep "^${PACKAGE}-[0-9].*" PACKAGES |tail -n1)
		mkdir -p packages/${PACKAGE}/RPMS/noarch
		cd packages/${PACKAGE}/RPMS/noarch
		curl -O $PKGS/$P
		cd ../../../..
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --nodeps packages/${PACKAGE}/RPMS/*/*
	else
		if ! ./build-package.sh -t $RPMTARGET $i; then
			echo "$i failed to build."
			exit 1
		fi
	fi

	if [ "$PACKAGE" = "binutils" ]; then
		# Special case: We want the -devel package for plugin-api.h, but we don't want
		# the binaries to override the host architecture binaries in the chroot
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/*-devel*
	elif [ "$PACKAGE" = "llvm" ]; then
		# We need LLVM libs in the buildroot for mesa, but we still need to run the HOST
		# versions of binaries such as clang or llvm-objdump.
		# Compare $PACKAGE, not $i: the NEEDED token is llvm:-pymlir:-crosscrt.
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/lib*
		# Host clang --rtlib=compiler-rt looks in its own resource
		# dir for $FULLTARGET/libclang_rt.builtins.a. Native llvm
		# ships that only for triples it built with crosscrt; a
		# bootstrap target may not be there. Copy builtins from
		# the clang RPM we just built (do not install the RPM —
		# that would replace host clang).
		clang_rpm=$(ls packages/${PACKAGE}/RPMS/*/clang-[0-9]*.rpm 2>/dev/null | head -n1)
		if [ -n "$clang_rpm" ]; then
			resdir=$(clang --print-resource-dir)
			dest="$resdir/lib/$FULLTARGET"
			rtmp=$(mktemp -d)
			rpm2cpio "$clang_rpm" | (cd "$rtmp" && cpio -idmu --quiet)
			src=$(find "$rtmp" -type d -name "$FULLTARGET" | head -n1)
			if [ -d "$src" ]; then
				sudo mkdir -p "$dest"
				sudo cp -a "$src"/. "$dest"/
			fi
			rm -rf "$rtmp"
		fi
	elif [ "$PACKAGE" = "systemd" ]; then
		# We need to exclude a few components for the time being, because the
		# user(x)/group(x) dependency scheme doesn't work in crosscompiled
		# packages
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps $(ls packages/${PACKAGE}/RPMS/*/* |grep -vE 'systemd-(oom|hwdb|journal-remote|resolved)') || :
	elif [ "$PACKAGE" != "$LIBC" -a "$PACKAGE" != "ninja" -a "$PACKAGE" != "make" -a "$PACKAGE" != "gcc" -a "$PACKAGE" != "filesystem" ]; then
		# In the case of LIBC/binutils/gcc, better to keep the crosscompiler's package
		# In the case of ninja/make/llvm, we need to run the HOST version, but
		# cmake and friends prefer anything in the sysroot
		# (we need to build ninja and make anyway, to have them available
		# in the final buildroot creation)
		# Compare $PACKAGE, not $i: entries such as glibc:-crosscompilers
		# and gcc:-crosscompilers would otherwise be installed into the
		# sysroot and override the cross toolchain.
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/*
	fi
	# Dynamic linker must be visible at both /lib and /lib64 inside
	# a 64-bit sysroot. clang's PT_INTERP is /lib on riscv64 and
	# /lib64 on loongarch64; qemu uses QEMU_LD_PREFIX + that path.
	# 32-bit loaders stay in /lib only. Relative links -- rpm -r
	# leaves glibc's absolute /lib -> /lib64 dangling outside the
	# sysroot.
	sys=/usr/$FULLTARGET
	sudo mkdir -p "$sys/lib"
	for src in "$sys/lib64"/ld-linux-*.so.*; do
		[ -e "$src" ] || continue
		base=$(basename "$src")
		[ -e "$sys/lib/$base" ] || sudo ln -sfn ../lib64/"$base" "$sys/lib/$base"
	done
	case $FULLTARGET in
	arm*|i[3-6]86*)
		;;
	*)
		sudo mkdir -p "$sys/lib64"
		for src in "$sys/lib"/ld-linux-*.so.*; do
			[ -e "$src" ] || continue
			base=$(basename "$src")
			[ -e "$sys/lib64/$base" ] || sudo ln -sfn ../lib/"$base" "$sys/lib64/$base"
		done
		;;
	esac
	# Target wayland-scanner is a riscv64 ELF. Meson looks it up via
	# pkg-config (PKG_CONFIG_SYSROOT_DIR prefixes the path) and tries
	# to run it; qemu cannot find the riscv64 interpreter on /lib.
	if [ "$PACKAGE" = "wayland" ] && [ -x /usr/bin/wayland-scanner ]; then
		sudo ln -sfn /usr/bin/wayland-scanner /usr/$FULLTARGET/usr/bin/wayland-scanner
	fi
done
# Get rid of some subpackages that pull in too many extra dependencies for a bootstrap chroot
rm -f packages/distro-release/RPMS/*/distro-release-desktop* packages/libsecret/RPMS/*/*-devel* packages/openssl/RPMS/*/openssl-perl* packages/systemd/RPMS/*/systemd-zsh-completion* packages/lvm2/RPMS/*/lvm2-dbusd-*
