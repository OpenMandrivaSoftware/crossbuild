#!/bin/sh
set -e

keepsudoalive() {
	# Keep sudo timestamp alive so we don't get timeouts
	# just because someone doesn't want to sit through a
	# package build that takes > $SUDO_TIMESTAMP_TIMEOUT
	(sudo -v; sleep 4m; keepsudoalive) &>/dev/null &
}

WIPE=false
while getopts "w" opt; do
	case $opt in
	w)
		# Wipe out previous root to make sure none of the script's
		# results are influenced by "leftovers"
		WIPE=true
		;;
	esac
done
shift $((OPTIND-1))

if [ -z "$1" ]; then
	RPMTARGET=riscv64-linux
else
	RPMTARGET="$1"
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

keepsudoalive

if $WIPE; then
	rpm -qa |grep cross-${FULLTARGET} |xargs sudo dnf -y erase || :
	sudo rm -rf /usr/${FULLTARGET}
fi

# Host side dependencies... Probably nowhere near complete
sudo dnf -y install task-devel texinfo asciidoc 'perl(Pod::Html)' nettle libtasn1-tools cmake 'pkgconfig(xkeyboard-config)' 'pkgconfig(wayland-protocols)' bpftool 'pkgconfig(fdisk)' 'pkgconfig(tss2-esys)' 'pkgconfig(libbpf)' 'pkgconfig(pwquality)' 'pkgconfig(libqrencode)' 'pkgconfig(libkmod)' 'pkgconfig(libmicrohttpd)' 'pkgconfig(liblz4)' 'pkgconfig(libseccomp)' cross-${FULLTARGET}-binutils cross-${FULLTARGET}-gcc cross-${FULLTARGET}-libc cross-${FULLTARGET}-kernel-headers console-setup glibc-i18ndata lzip gtk-doc
# FIXME the presence of bash-completion.pc on the host system causes systemd
# and other meson based builds to install the completions file in a bogus
# location. For now, let's just make sure the file isn't there...
sudo dnf -y erase bash-completion-devel || :

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
esac

# FIXME we should fix the search path instead
[ -e /usr/$FULLTARGET/lib/pkgconfig ] || [ -d /usr/$FULLTARGET/lib64 ] && sudo ln -sf ../lib64/pkgconfig /usr/$FULLTARGET/lib/pkgconfig
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
# - libxau is a dependency of libxcb
#
# Anything in the list after llvm is there to fulfill runtime dependencies of the
# packages built before. If you want to build the minimal possible system, you can
# leave some of those out and remove a couple of subpackages.

ABF_DOWNLOADS=http://abf-downloads.openmandriva.org/
OMV_VERSION=cooker
PKGS=${ABF_DOWNLOADS}/${OMV_VERSION}/repository/x86_64/main/release/
curl -s -L $PKGS |grep '^<a' |cut -d'"' -f2 >PACKAGES

for i in $LIBC:-crosscompilers ncurses:-cplusplus readline bash make ninja zlib-ng gzip bzip2 xz libb2 lz4 zstd file libarchive libtirpc:-gss libnsl libxcrypt pam attr acl lua:-pgo libgpg-error libgcrypt sqlite libcap expat pcre2 json-c lksctp-tools openssl libssh curl:-gnutls:-mbedtls libmicrohttpd elfutils libbpf util-linux:bootstrap cracklib libpwquality:-python x11-proto-devel:-python2 libxau libxcb x11-xtrans-devel libx11 libxkbfile xkbcomp dbus:-systemd tpm2-tss libidn2 libpng:-pgo qrencode kmod gmp libunistring nettle:-pgo libtasn1 brotli:-pgo:-python libffi bash-completion-devel p11-kit:bootstrap gnutls:-pgo icu libxml2:-pgo:-python wayland wayland-protocols-devel libxkbcommon glib2.0:-pgo:-gtkdoc libseccomp systemd:bootstrap popt libxrender libxext libXrandr vulkan-headers vulkan-loader mpfr libmpc isl binutils gcc rpm llvm grep sed gawk coreutils pkgconf kbd python:-tkinter filesystem pbzip2 rootcerts pigz:-pgo libxcvt xcb-util-renderutil xcb-util xcb-util-image xcb-util-wm xcb-util-keysyms pixman:-pgo libfontenc graphite2 freetype:-rsvg:-harfbuzz fontconfig liblzo cairo harfbuzz:-gir freetype:-rsvg libxfont2 kernel xkeyboard-config crontabs libedit python-six lz4 setup basesystem perl vim:-gui; do
	PACKAGE="${i/:*}"
	if [ "$PACKAGE" = "systemd" ]; then
		# FIXME this is nasty: bash-completion-devel is needed for p11-kit's build system,
		# but having it in the chroot breaks building systemd by making it install its
		# completions in the wrong place.
		# Installing a build dependency for one package and removing it before another is
		# built "fixes" the problem, but of course isn't a nice thing to do.
		sudo rpm -r /usr/$FULLTARGET -e bash-completion-devel || :
	fi
	if grep -q "^${PACKAGE}-[0-9].*\.noarch\.rpm" PACKAGES; then
		# We can save some time on noarch packages...
		P=$(grep "^${PACKAGE}-[0-9].*" PACKAGES |tail -n1)
		mkdir -p packages/${PACKAGE}/RPMS/noarch
		cd packages/${PACKAGE}/RPMS/noarch
		curl -O $PKGS/$P
		cd ../../../..
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --nodeps packages/${PACKAGE}/RPMS/*/*
	else
		./build-package.sh -t $RPMTARGET $i
	fi

	if [ "$i" = "binutils" ]; then
		# Special case: We want the -devel package for plugin-api.h, but we don't want
		# the binaries to override the host architecture binaries in the chroot
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/*-devel*
	elif [ "$i" != "$LIBC" -a "$i" != "ninja" -a "$i" != "make" -a "$i" != "gcc" -a "$i" != "filesystem" -a "$i" != "llvm" ]; then
		# In the case of LIBC/binutils/gcc, better to keep the crosscompiler's package
		# In the case of ninja/make/llvm, we need to run the HOST version, but
		# cmake and friends prefer anything in the sysroot
		# (we need to build ninja and make anyway, to have them available
		# in the final buildroot creation)
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/*
	fi
done
