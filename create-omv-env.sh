#!/bin/sh
set -e

keepsudoalive() {
	# Keep sudo timestamp alive so we don't get timeouts
	# just because someone doesn't want to sit through a
	# package build that takes > $SUDO_TIMESTAMP_TIMEOUT
	# -v always prompts here after the ticket expires; NOPASSWD works for real commands
	sudo -n true
	(sleep 4m; keepsudoalive) &>/dev/null &
}

WIPE=false
while getopts "wr:" opt; do
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

NEEDED="$LIBC:-crosscompilers ncurses:-cplusplus readline bash make ninja zlib-ng gzip bzip2 xz libb2 lz4 zstd file libarchive libtirpc:-gss libnsl libxcrypt gdbm lksctp-tools openssl sltdl sqlite cracklib:-python cyrus-sasl:bootstrap:-mysql:-pgsql:-krb5 libevent perl openldap libcap-ng audit:-python:-systemd pam:bootstrap attr acl lua:-pgo libgpg-error libgcrypt libcap expat pcre2 json-c libssh libunistring libidn2 libpsl curl:-gnutls:-mbedtls:-kerberos libmicrohttpd elfutils libbpf util-linux:bootstrap libpwquality:-python x11-proto-devel:-python2 libxau libxcb x11-sgml-doctools x11-xtrans-devel libx11 libxkbfile xkbcomp dbus:-systemd tpm2-tss:-ftdi libpng:-pgo qrencode kmod gmp nettle:-pgo libtasn1 brotli:-pgo:-python libffi bash-completion-devel p11-kit:bootstrap unbound gnutls:-pgo icu libxml2:-pgo:-python wayland wayland-protocols-devel libxkbcommon glib2.0:-pgo:-gtkdoc:-introspection:-systemtap:-sysprof libseccomp python-pyelftools systemd:bootstrap pam popt libxrender libxext libXrandr vulkan-headers vulkan-loader mpfr libmpc isl binutils:-gold python:-tkinter bubblewrap rpm:-openmp:-selinux:-audit z3 llvm:-pymlir:-crosscrt grep sed gawk coreutils pkgconf kbd python:-tkinter filesystem pbzip2 rootcerts pigz:-pgo libxcvt xcb-util-renderutil xcb-util xcb-util-image xcb-util-wm xcb-util-keysyms pixman:-pgo libfontenc graphite2 freetype:-rsvg:-harfbuzz fontconfig liblzo cairo harfbuzz:-gir freetype:-rsvg libxfont2 kernel:-desktop:-desktop_gcc:-server_gcc xkeyboard-config xkeyboard-config-devel crontabs libedit python-six lz4 setup basesystem lua libmd libbsd shadow xdg-utils which unzip uchardet groff:-x11 fuse e2fsprogs procps-ng psmisc time wget findutils patch rootfiles etcskel diffutils publicsuffix-list publicsuffix-list-dafsa libksba npth libassuan autoconf automake slibtool gnupg cmake:bootstrap meson m4 distro-release hostname iputils less libutempter logrotate net-tools:-bluetooth libsecret:-gir pinentry:-qt6:-qt5:-gtk2:-gnome:-fltk xxhash debugedit dwz gdb rpm-helper lsb-release ppl shared-mime-info go-srpm-macros python-packaging python-pkg-resources rust-srpm-macros rpmlint spec-helper zchunk libsolv check librepo yaml libmodulemd:-gir:-python cppunit toml11 fmt sdbus-cpp libxmlb:-gir libfyaml libstemmer appstream:-qt6:-vala:-gir swig yaml-cpp libpkgmanifest dnf:-ruby desktop-file-utils libice libsm libxt libxmu xset xprop chrpath perl-srpm-macros libaio pyudev keyutils libnvme lvm2 argon2 cryptsetup systemd gettext:-check:-java:-csharp:-emacs run-parts pcre onig slang newt chkconfig perl-File-HomeDir libxdmcp libglvnd libxft fribidi pango:bootstrap rrdtool lm_sensors libdrm libunwind:-tests libxshmfence libxfixes libva libvdpau libxxf86vm mesa:-rust:-rusticl libepoxy libsepol libselinux:bootstrap libpciaccess xlibre perl-Module-Build boost systemtap:-avahi:-java python-parsing filesystem rgb gcc:-crosscompilers perl-File-Which libevdev abattis-cantarell-fonts plymouth mkcomposecache xauth efi-filesystem x11-font-alias x11-font-cursor-misc x11-font-misc-misc mkfontdir libfontenc mkfontscale hwdata mtdev libinput:bootstrap x11-driver-input-libinput fonts-ttf-dejavu fontpackages-filesystem dracut timezone duktape polkit:-gir satyr augeas bash-completion python-pybeam hunspell enchant2:-aspell:-hspell:-voikko python-enchant python-magic pyxdg python-tomli python-pip libcomps glu libxi freeglut python-setuptools python-wheel python-tomli-w python-flit-core python-dateutil python-construct python-zstandard python-systemd perl-XML-Parser gptfdisk userspace-rcu multipath-tools sudo libusb usbutils sysfsutils dbus-broker grub2 gnu-config perl-Class-Inspector perl-File-ShareDir console-setup x11-data-cursor-themes httplib c-ares pciutils efivar efibootmgr vim:-gui:-ruby:-lua car"
# Not needed for a chroot, but useful for images generated with os-image-builder
EXTRAS="dracut-modules-growroot cloud-utils"
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
	# glibc ships /lib/ld-linux-* -> /lib64/ld-linux-* as an absolute
	# symlink. rpm -r does not rewrite it, so ld --sysroot follows the
	# link out of the sysroot and cannot create executables.
	if [ -d /usr/$FULLTARGET/lib64 ] || [ -d /usr/$FULLTARGET/usr/lib64 ]; then
		sudo mkdir -p /usr/$FULLTARGET/lib
		for ld in /usr/$FULLTARGET/lib64/ld-linux-*.so.* /usr/$FULLTARGET/usr/lib64/ld-linux-*.so.*; do
			[ -e "$ld" ] || continue
			sudo ln -sfn ../lib64/$(basename "$ld") /usr/$FULLTARGET/lib/$(basename "$ld")
		done
	fi
	# Target wayland-scanner is a riscv64 ELF. Meson looks it up via
	# pkg-config (PKG_CONFIG_SYSROOT_DIR prefixes the path) and tries
	# to run it; qemu cannot find the riscv64 interpreter on /lib.
	if [ "$PACKAGE" = "wayland" ] && [ -x /usr/bin/wayland-scanner ]; then
		sudo ln -sfn /usr/bin/wayland-scanner /usr/$FULLTARGET/usr/bin/wayland-scanner
	fi
done
# Get rid of some subpackages that pull in too many extra dependencies for a bootstrap chroot
rm -f packages/distro-release/RPMS/*/distro-release-desktop* packages/libsecret/RPMS/*/*-devel* packages/openssl/RPMS/*/openssl-perl* packages/systemd/RPMS/*/systemd-zsh-completion* packages/lvm2/RPMS/*/lvm2-dbusd-*
