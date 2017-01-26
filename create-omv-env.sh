#!/bin/sh
set -e
set -x

keepsudoalive() {
	# Keep sudo timestamp alive so we don't get timeouts
	# just because someone doesn't want to sit through a
	# package build that takes > $SUDO_TIMESTAMP_TIMEOUT
	(sudo true; sleep 4m; keepsudoalive) &>/dev/null &
}

RPMTARGET=riscv64-linux
FULLTARGET=riscv64-openmandriva-linux-gnu

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

if ! grep ^%__cc /usr/lib/rpm/platform/$RPMTARGET/macros; then
	sudo sed -i -e "\$a\%__cc $FULLTARGET-gcc" /usr/lib/rpm/platform/$RPMTARGET/macros
	sudo sed -i -e "\$a\%__cxx $FULLTARGET-g++" /usr/lib/rpm/platform/$RPMTARGET/macros
fi

sudo mkdir -p /usr/$FULLTARGET/share/cmake
(cat <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR $ARCH)
                
set(CMAKE_C_COMPILER "/usr/bin/$FULLTARGET-gcc")
set(CMAKE_CXX_COMPILER "/usr/bin/$FULLTARGET-g++")
                
set(CMAKE_FIND_ROOT_PATH "/usr/$FULLTARGET")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
) |sudo tee /usr/$FULLTARGET/share/cmake/$FULLTARGET.toolchain

# FIXME don't hardcode endianness
sudo mkdir -p /usr/$FULLTARGET/share/meson
(cat <<EOF
[binaries]
c = '/usr/bin/$FULLTARGET-gcc'
cpp = '/usr/bin/$FULLTARGET-g++'
ar = '/usr/bin/$FULLTARGET-ar'
strip = '/usr/bin/$FULLTARGET-strip'
pkgconfig = '/usr/bin/pkg-config'

[host_machine]
system = 'linux'
cpu_family = '$ARCH'
cpu = '$ARCH'
endian = 'little'

[properties]
sys_root = '/usr/$FULLTARGET'
pkg_config_libdir = '/usr/$FULLTARGET/usr/lib64/pkgconfig'
EOF
) |sudo tee /usr/$FULLTARGET/share/meson/$FULLTARGET.cross

# FIXME we should fix the search path instead
[ -e /usr/$FULLTARGET/lib/pkgconfig ] || sudo ln -sf ../lib64/pkgconfig /usr/$FULLTARGET/lib/pkgconfig
[ -h /usr/$FULLTARGET/sys-root ] || sudo ln -sf . /usr/$FULLTARGET/sys-root

keepsudoalive

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

for i in $LIBC:-crosscompilers ncurses:-cplusplus readline bash make ninja zlib-ng gzip bzip2 xz libb2 lz4 zstd file libarchive libtirpc:-gss libnsl pam attr acl lua libgpg-error libgcrypt sqlite libcap expat pcre2 json-c lksctp-tools openssl libssh curl:-gnutls:-mbedtls libmicrohttpd elfutils libbpf util-linux:bootstrap cracklib libpwquality:-python x11-proto-devel:-python2 libxau libxcb x11-xtrans-devel libx11 libxkbfile xkbcomp dbus:-systemd tpm2-tss libidn2 libpng:-pgo qrencode kmod gmp libunistring nettle:-pgo libtasn1 brotli:-pgo:-python libffi p11-kit:bootstrap gnutls:-pgo icu libxml2:-pgo wayland libxkbcommon glib2.0:-pgo:-gtkdoc systemd:bootstrap popt libxrender libxext libXrandr vulkan-headers vulkan-loader mpfr libmpc isl binutils gcc rpm; do
	./build-package.sh $i
	if [ "$i" != "$LIBC" -a "$i" != "ninja" -a "$i" != "make" -a "$i" != "binutils" -a "$i" != "gcc" ]; then
		# In the case of LIBC/binutils/gcc, better to keep the crosscompiler's package
		# In the case of ninja/make, we need to run the HOST version, but
		# cmake and friends prefer anything in the sysroot
		# (we need to build ninja and make anyway, to have them available
		# in the final buildroot creation)
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${i/:*}/RPMS/*/*
	fi
done
