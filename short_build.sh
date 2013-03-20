#!/bin/sh
TARGET="$1"
[ -z "$TARGET" ] && TARGET=aarch64-mandriva-linux-gnu
TARGET="`/usr/share/libtool/config/config.sub $TARGET`"
if [ -z "$ARCH" ]; then
	ARCH=`echo $TARGET |cut -d- -f1`
	case $ARCH in
	arm*)
		ARCH=arm
		;;
	i?86|pentium?|athlon)
		ARCH=i386
		;;
	x86_64|amd64|intel64)
		ARCH=x86_64
		;;
	mips*)
		ARCH=mips
		;;
	*)
		# Let's take a good guess and assume ARCH == CPU
		;;
	esac
fi

GOLD=true
KERNELARCH=$ARCH
case $ARCH in
aarch64)
	GOLD=false
	KERNELARCH=arm64
	;;
esac

CPU=`echo $TARGET |cut -d- -f1`
VENDOR=`echo $TARGET |cut -d- -f2`
OS=`echo $TARGET |cut -d- -f3`
SUFFIX=`echo $TARGET |cut -d- -f4-`
if [ -n "$SUFFIX" ]; then
	SUFFIX="-$SUFFIX"
else
	SUFFIX="%nil"
fi

CPUFLAGS=""
case $CPU in
armv6j)
	GCCEXTRAARGS="--with-cpu=arm1136jf-s --with-float=hard --with-fpu=vfp"
	CPUFLAGS="-mcpu=arm1136jf-s"
	;;
esac


LIBC=glibc
USR=/usr
case $SUFFIX in
-android*)
	LIBC=bionic
	USR=/system
	GCCEXTRAARGS="$GCCEXTRAARGS --disable-libstdc__-v3 --disable-sjlj-exceptions --disable-libitm"
	;;
-uclibc)
	LIBC=uclibc
	;;
esac

case $LIBC in
glibc)
	LIBCPACKAGE=glibc
	;;
uclibc)
	LIBCPACKAGE=uClibc
	;;
esac

SYSROOT=/usr/$TARGET/sys-root
SMP_MFLAGS="-j`getconf _NPROCESSORS_ONLN`"
[ "$SMP_MFLAGS" = "-j" ] && SMP_MFLAGS="-j4"

set -e

cd `dirname $0`
DIR=`pwd`
for i in binutils gcc $LIBCPACKAGE; do
	[ -d $i ] && continue
	abf get openmandriva/$i
	cd $i
	abf fetch
	mkdir BUILD
	rpm --define "_specdir `pwd`" --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" -bp --nodeps *.spec
	cd ..
done
# FIXME merge with the above once we have a decent kernel
# We need 3.8 so we get the uabi kernel header division
# But let's check it out into an ABF-like directory structure
if ! [ -d kernel ]; then
	mkdir kernel
	mkdir kernel/BUILD
	cd kernel/BUILD
	git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git kernel-3.8
	cd kernel-3.8
	git checkout -b v3.8 v3.8
	cd ../../..
fi

echo ========================================================================
echo cmake configs
echo ========================================================================
cat >$TARGET.toolchain <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR $ARCH)

set(CMAKE_C_COMPILER "$USR/bin/$TARGET-gcc")
set(CMAKE_CXX_COMPILER "$USR/bin/$TARGET-g++")

set(CMAKE_FIND_ROOT_PATH "$SYSROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
sudo mkdir -p $USR/$TARGET/share/cmake
sudo cp $TARGET.toolchain $USR/$TARGET/share/cmake/

echo ========================================================================
echo rpm configs
echo ========================================================================
# Also needed for versions of rpm prior to 5.2.1-0.20100309.1ark:
#%_build_arch `uname -m`
#%_build_platform `uname -m`-`uname -i`-linux-gnu
#%_build %_build_platform
#%_build_alias %_build%nil
#%_build_vendor `uname -i`
#%_build_os linux-gnu

cat >macros <<EOF
%_host	$TARGET
%_host_alias	$TARGET%nil
%_target_platform	$TARGET
%_host_vendor	$VENDOR
%_host_os	$OS
%_gnu	$SUFFIX

%__ar	$TARGET-ar
%__as	$TARGET-as
%__cc	$TARGET-gcc
%__cpp	$TARGET-gcc -E
%__cxx	$TARGET-g++
%__ld	$TARGET-ld
%__nm	$TARGET-nm
%__objcopy	$TARGET-objcopy
%__objdump	$TARGET-objdump
%__ranlib	$TARGET-ranlib
%__strip	$TARGET-strip

%_prefix	$USR

%optflags -O2	$CPUFLAGS -fomit-frame-pointer -fweb -frename-registers -Wl,-O2,-z,combreloc,-z,relro,--enable-new-dtags,--hash-style=gnu -g
EOF

# This is a bit ugly, since RPM platforms are only a CPU-OS combo.
# This is often not sufficient (arm-mandriva-linux-gnueabi vs.
# arm-mandriva-linux-uclibc vs. arm-mandriva-linux-androideabi)...
RPMOS=$OS
if [ "$SUFFIX" != "-gnu" ]; then
	RPMOS=`echo $SUFFIX |cut -b2-`
fi

if [ -d /usr/lib/rpm/platform/$CPU-$RPMOS ]; then
	echo "RPM macros for $CPU-$RPMOS already exist. Overwrite?"
	read r
	if echo $r |grep -q y; then
		sudo rm -rf /usr/lib/rpm/platform/$CPU-$RPMOS
	fi
fi
if ! [ -d /usr/lib/rpm/platform/$CPU-$RPMOS ]; then
	sudo mkdir -p /usr/lib/rpm/platform/$CPU-$RPMOS
	sudo cp macros /usr/lib/rpm/platform/$CPU-$RPMOS/macros
fi

# Basic RPMs to get a build environment up so we can continue building on the target...
#rm -rf packages
#mkdir packages
cd packages
#for i in filesystem setup bash attr strace; do
#for i in filesystem setup bash gmp mpfr grep gzip zlib ncurses less curl gettext bzip2 acl attr findutils tar diffutils gpm sqlite make chrpath libsigsegv expat libidn ; do
for i in bzip2 findutils tar diffutils gpm sqlite make chrpath libsigsegv expat libidn ; do
#for i in sed glib2.0 openssl gamin  wget time popt ppl pcre p11-kit nano; do
	abf get openmandriva/$i
# i prefer abb
#	abb clone $i
	cd $i
	abf fetch
	rm -rf BUILD RPMS SRPMS
	rpm -ba --nodeps --target $TARGET --without check --without dietlibc --without diet --without minizip --without uclibc --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec
	# nodeps is necessary at this point because libc and friends aren't coming from packages yet
	sudo rpm --root $SYSROOT --ignorearch -Uvh --force --nodeps RPMS/*/*.rpm
	cd ..
done
