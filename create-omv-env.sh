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
# FIXME requiring cmake(LibSolv) on the host side is a nasty workaround
# for libdnf's cmake files not finding FindLibSolv in the sysroot. Since
# all it produces is -lsolv, the fact that it's taking stuff from the
# host doesn't have serious drawbacks, so we can leave it for now.
# FIXME Host pyudev is required to make lvm2's configure script happy,
# but it should really check the sysroot instead.
# FIXME rrdtool looks for host pangocairo headers, but really needs
# target headers
# FIXME glibmm and similar rarely used cruft is required by enchant2, which
# in turn is required by rpmlint. Trim down rpmlint at some point?
# Not a typo, as weird as it is, xbiff is actually needed (by mkcomposecache)
sudo dnf -y install task-devel texinfo asciidoc 'perl(Pod::Html)' 'perl(open)' nettle libtasn1-tools cmake 'pkgconfig(systemd)' 'pkgconfig(xkeyboard-config)' 'pkgconfig(wayland-protocols)' bpftool 'pkgconfig(fdisk)' 'pkgconfig(tss2-esys)' 'pkgconfig(libbpf)' 'pkgconfig(pwquality)' 'pkgconfig(libqrencode)' 'pkgconfig(libkmod)' 'pkgconfig(libmicrohttpd)' 'pkgconfig(liblz4)' 'pkgconfig(libseccomp)' 'pkgconfig(pangocairo)' cross-${FULLTARGET}-binutils cross-${FULLTARGET}-gcc cross-${FULLTARGET}-libc cross-${FULLTARGET}-kernel-headers console-setup glibc-i18ndata lzip gtk-doc luajit-lpeg luajit-mpack 'cmake(LibSolv)' pyudev 'pkgconfig(dbus-1)' libmpc-devel publicsuffix-list slibtool x11-server-xvfb xbiff xkbcomp mkcomposecache x11-xtrans-devel
# FIXME this should really be fixed properly, but for now, this workaround will do:
# pam detects the HOST systemd headers and then fails to build systemd related bits because
# the target headers aren't there yet.
# To make matters worse, we need HOST dbus-1 headers to build systemd (correctly, because it
# needs to build a native version of generator tools), but dbus-1 devel depends on systemd
# devel.
# Remove this once crosscompiling pam is fixed.
sudo rpm -e --nodeps lib64systemd-devel || :
# FIXME If HOST valgrind devel files are detected, mesa tries to use TARGET valgrind
# and fails because it doesn't exist yet
sudo dnf -y erase valgrind-devel || :
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

# FIXME this is nasty, we should fix python instead
sudo sed -i -e "s| 'LIBDIR':.*| 'LIBDIR': '/no/we/do/not/like/dashL/usr/lib',|" /usr/lib64/python3.11/_sysconfigdata__*.py

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

for i in $LIBC:-crosscompilers ncurses:-cplusplus readline bash make ninja zlib-ng gzip bzip2 xz libb2 lz4 zstd file libarchive libtirpc:-gss libnsl libxcrypt pam attr acl lua:-pgo libgpg-error libgcrypt sqlite libcap expat pcre2 json-c lksctp-tools openssl libssh libunistring libidn2 libpsl curl:-gnutls:-mbedtls libmicrohttpd elfutils libbpf util-linux:bootstrap cracklib libpwquality:-python x11-proto-devel:-python2 libxau libxcb x11-xtrans-devel libx11 libxkbfile xkbcomp dbus:-systemd tpm2-tss libpng:-pgo qrencode kmod gmp nettle:-pgo libtasn1 brotli:-pgo:-python libffi bash-completion-devel p11-kit:bootstrap gnutls:-pgo icu libxml2:-pgo:-python wayland wayland-protocols-devel libxkbcommon glib2.0:-pgo:-gtkdoc libseccomp python-pyelftools systemd:bootstrap popt libxrender libxext libXrandr vulkan-headers vulkan-loader mpfr libmpc isl binutils gcc python:-tkinter bubblewrap rpm llvm grep sed gawk coreutils pkgconf kbd python:-tkinter filesystem pbzip2 rootcerts pigz:-pgo libxcvt xcb-util-renderutil xcb-util xcb-util-image xcb-util-wm xcb-util-keysyms pixman:-pgo libfontenc graphite2 freetype:-rsvg:-harfbuzz fontconfig liblzo cairo harfbuzz:-gir freetype:-rsvg libxfont2 kernel xkeyboard-config xkeyboard-config-devel crontabs libedit python-six lz4 setup basesystem gdbm perl luajit lua lua-lpeg lua-mpack libuv libluv unibilium libtermkey libvterm msgpack tree-sitter neovim libmd libbsd shadow xdg-utils which unzip groff:-x11 fuse e2fsprogs procps-ng psmisc time wget findutils patch rootfiles etcskel diffutils publicsuffix-list publicsuffix-list-dafsa libksba npth libassuan autoconf automake libtool cyrus-sasl:bootstrap:-mysql:-pgsql:-krb5 libevent openldap gnupg diffutils cmake:bootstrap meson m4 common-licenses distro-release hostname iputils less libutempter logrotate net-tools:-bluetooth libsecret:-gir pinentry:-qt6:-qt5:-gtk2:-gnome:-fltk debugedit xxhash dwz gdb rpm-helper lsb-release ppl shared-mime-info go-srpm-macros python-packaging python-pkg-resources rust-srpm-macros rpmlint spec-helper zchunk libsolv check librepo yaml libmodulemd:-gir:-python cppunit libdnf dnf python-dnf dnf-data toml11 fmt sdbus-cpp dnf5:-ruby desktop-file-utils libice libsm libxt libxmu xset xprop chrpath pam_userpass perl-srpm-macros libaio pyudev lvm2 argon2 cryptsetup systemd gettext:-check:-java:-csharp:-emacs run-parts pcre onig slang newt chkconfig perl-File-HomeDir libxdmcp libglvnd libxft fribidi pango:bootstrap rrdtool lm_sensors libdrm libunwind libxshmfence libxfixes libva libvdpau libxxf86vm mesa:-rust:-rusticl libepoxy tcp_wrappers libcap-ng audit libsepol libselinux:bootstrap libpciaccess x11-server perl-Module-Build systemtap:-avahi:-java python-parsing filesystem rgb gcc:-crosscompilers perl-File-Which libevdev abattis-cantarell-fonts plymouth mkcomposecache xauth efi-filesystem x11-font-alias x11-font-cursor-misc x11-font-misc-misc mkfontdir mkfontscale hwdata mtdev libinput:bootstrap x11-driver-input-libinput fonts-ttf-dejavu fontpackages-filesystem dracut timezone duktape polkit:-gir satyr augeas bash-completion python-pybeam python-enchant python-magic pyxdg python-tomli python-pip libcomps glu libxi freeglut python-dnf-plugins-core dnf-plugins-core hunspell python-setuptools python-wheel python-tomli-w python-flit-core python-dateutil aspell python-construct python-zstandard python-systemd libsigc-2.0 glibmm2.4 libxmlpp hfst-ospell libvoikko hspell enchant2 mm-common perl-XML-Parser voikko-fi; do
	PACKAGE="${i/:*}"
	if [ "$PACKAGE" = "systemd" ]; then
		# FIXME this is nasty: bash-completion-devel is needed for p11-kit's build system,
		# but having it in the chroot breaks building systemd by making it install its
		# completions in the wrong place.
		# Installing a build dependency for one package and removing it before another is
		# built "fixes" the problem, but of course isn't a nice thing to do.
		sudo rpm -r /usr/$FULLTARGET -e bash-completion-devel || :
	elif [ "$PACKAGE" = "dnf5" ]; then
		# dnf5 needs it...
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --nodeps packages/bash-completion-devel/RPMS/*/*

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
	elif [ "$i" = "llvm" ]; then
		# We need LLVM libs in the buildroot for mesa, but we still need to run the HOST
		# versions of binaries such as clang or llvm-objdump
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/lib*
	elif [ "$i" != "$LIBC" -a "$i" != "ninja" -a "$i" != "make" -a "$i" != "gcc" -a "$i" != "filesystem" ]; then
		# In the case of LIBC/binutils/gcc, better to keep the crosscompiler's package
		# In the case of ninja/make/llvm, we need to run the HOST version, but
		# cmake and friends prefer anything in the sysroot
		# (we need to build ninja and make anyway, to have them available
		# in the final buildroot creation)
		sudo rpm -r /usr/$FULLTARGET -Uvh --force --noscripts --ignorearch --nodeps packages/${PACKAGE}/RPMS/*/*
	fi
done
# Get rid of some subpackages that pull in too many extra dependencies for a bootstrap chroot
rm -f packages/distro-release/RPMS/*/distro-release-desktop* packages/libsecret/RPMS/*/*-devel* packages/openssl/RPMS/*/openssl-perl* packages/systemd/RPMS/*/systemd-zsh-completion* packages/lvm2/RPMS/*/lvm2-dbusd-*
