#!/bin/sh
TARGET="$1"
[ -z "$TARGET" ] && TARGET=x86_64-openmandriva-linux-musl
#[ -z "$TARGET" ] && TARGET=aarch64-mandriva-linux-gnu
#[ -z "$TARGET" ] && TARGET=armv7hf-mandriva-linux-gnu
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

SYSROOT=/usr/$TARGET/sys-root
SMP_MFLAGS="-j`getconf _NPROCESSORS_ONLN`"
[ "$SMP_MFLAGS" = "-j" ] && SMP_MFLAGS="-j4"

set -e

cd `dirname $0`
DIR=`pwd`
for i in binutils kernel musl; do
	[ -d $i ] && continue
	abf get openmandriva/$i
	cd $i
	abf fetch
	mkdir BUILD
	rpm --define "_specdir `pwd`" --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" -bp --nodeps *.spec
	cd ..
done

sudo rm -rf /usr/$TARGET
sudo rm -rf $SYSROOT
sudo mkdir -p $SYSROOT

echo ========================================================================
echo binutils
echo ========================================================================
cd binutils/BUILD/*
rm -rf build ; mkdir build
cd build
../configure --prefix=/usr --target=$TARGET --with-sysroot=$SYSROOT --enable-ld --enable-gold=default --enable-plugins --enable-threads --enable-initfini-array
make $SMP_MFLAGS
sudo make install
cd ../../../..
rm -rf ld.bfd ; mkdir ld.bfd ; ln -s /usr/bin/$TARGET-ld.bfd ld.bfd/$TARGET-ld ; rm -rf binutils.bfd ; mkdir binutils.bfd ; ln -s /usr/$TARGET/bin/* binutils.bfd ; ln -sf ld.bfd binutils.bfd/ld

echo ========================================================================
echo toolchain wrappers
echo ========================================================================
# Some stuff (kernel etc.) insists on being able to invoke a crosscompiler as
# $TARGET-gcc or $TARGET-cc -- passing parameters as in
# clang -target $TARGET --sysroot=$SYSROOT isn't supported in those Makefiles
# For the kernel in particular, we need -no-integrated-as as well, to take
# care of the inline assembly hacks in Kbuild. We'll get rid of that flag
# later.
cat >$TARGET-cc <<EOF
#!/bin/sh
exec clang -target $TARGET -no-integrated-as --sysroot=$SYSROOT "\$@"
EOF
cat >$TARGET-c++ <<EOF
#!/bin/sh
exec clang++ -target $TARGET --sysroot=$SYSROOT "\$@"
EOF
chmod +x $TARGET-cc $TARGET-c++
sudo mv $TARGET-cc $TARGET-c++ /usr/bin
sudo ln -sf $TARGET-cc /usr/bin/$TARGET-gcc
sudo ln -sf $TARGET-c++ /usr/bin/$TARGET-g++

echo ========================================================================
echo kernel headers
echo ========================================================================
# Just the headers for now...
cd kernel/BUILD/kernel-*/linux-*
make ARCH=$KERNELARCH CROSS_COMPILE=$TARGET- defconfig
make ARCH=$KERNELARCH CROSS_COMPILE=$TARGET- prepare0 prepare1 prepare2 prepare3
sudo make ARCH=$KERNELARCH CROSS_COMPILE=$TARGET- INSTALL_HDR_PATH=$SYSROOT/usr headers_install
cd ../../../..

# Let's get rid of -no-integrated-as now...
sudo sed -i -e 's, -no-integrated-as,,' /usr/bin/$TARGET-gcc

echo ========================================================================
echo libc
echo ========================================================================
cd musl/BUILD/*
CROSS_COMPILE=$TARGET- CC=/usr/bin/$TARGET-gcc ./configure \
	--prefix=/usr \
	--exec-prefix=/usr \
	--libdir=/usr/lib \
	--includedir=/usr/include \
	--bindir=/usr/bin \
	--syslibdir=/lib \
	--enable-shared \
	--enable-static
make $SMP_MFLAGS CROSS_COMPILE=$TARGET- CC=/usr/bin/$TARGET-cc
sudo make install DESTDIR=$SYSROOT
cd ../../..
sudo ln -s sys-root/usr/include /usr/$TARGET/sys-include

echo ========================================================================
echo cmake configs
echo ========================================================================
cat >$TARGET.toolchain <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR $ARCH)

set(CMAKE_C_COMPILER "/usr/bin/$TARGET-cc")
set(CMAKE_CXX_COMPILER "/usr/bin/$TARGET-c++")

set(CMAKE_FIND_ROOT_PATH "$SYSROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
sudo mkdir -p /usr/$TARGET/share/cmake
sudo cp $TARGET.toolchain /usr/$TARGET/share/cmake/

echo ========================================================================
echo rpm configs
echo ========================================================================

cat >macros <<EOF
%_build_arch `uname -m`
%_build_platform `uname -m`-`uname -i`-linux-gnu
%_build %_build_platform
%_build_alias %_build%nil
%_build_vendor `uname -i`
%_build_os linux-gnu

%_host	$TARGET
%_host_alias	$TARGET%nil
%_target_platform	$TARGET
%_host_vendor	$VENDOR
%_host_os	$OS
%_gnu	$SUFFIX

%__ar	$TARGET-ar
%__as	$TARGET-as
%__cc	$TARGET-cc
%__cpp	$TARGET-cc -E
%__cxx	$TARGET-c++
%__ld	$TARGET-ld
%__nm	$TARGET-nm
%__objcopy	$TARGET-objcopy
%__objdump	$TARGET-objdump
%__ranlib	$TARGET-ranlib
%__strip	$TARGET-strip

%_prefix	/usr

%optflags -O2	$CPUFLAGS -fomit-frame-pointer -fweb -frename-registers -Wl,-O2,-z,combreloc,-z,relro,--enable-new-dtags,--hash-style=gnu -g
EOF

if echo $TARGET |grep x32; then
	echo >>macros
	echo '%_lib	libx32' >>macros
	# Since we aren't building multi-arch sysroots (for now),
	# make lib and lib64 the same -- compilers tend not to
	# look in lib64 inside a sysroot (e.g. aarch64, gcc 4.7.x)
	sudo ln -s lib $SYSROOT/libx32
	sudo ln -s lib $SYSROOT/usr/libx32
	sudo ln -s lib $SYSROOT/lib64
	sudo ln -s lib $SYSROOT/usr/lib64
elif echo $TARGET |grep -qE '(64|s390x|ia32e)-'; then
	echo >>macros
	echo '%_lib	lib64' >>macros
	# Since we aren't building multi-arch sysroots (for now),
	# make lib and lib64 the same -- compilers tend not to
	# look in lib64 inside a sysroot (e.g. aarch64, gcc 4.7.x)
	sudo ln -s lib $SYSROOT/lib64
	sudo ln -s lib $SYSROOT/usr/lib64
fi

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
rm -rf packages
mkdir packages
cd packages
for i in iso-codes filesystem setup musl ncurses mksh toybox; do
	case $i in
	ncurses)
		# Depending on our target, we may not have an STL yet
		EXTRA_RPMFLAGS="--without cplusplus"
		;;
	mksh)
		EXTRA_RPMFLAGS="--with bin_sh"
		;;
	*)
		EXTRA_RPMFLAGS=""
		;;
	esac
	abf get openmandriva/$i
	cd $i
	abf fetch
	rm -rf BUILD RPMS SRPMS
	echo "Running: rpm -ba --target $TARGET --with system_libc --without uclibc $EXTRA_RPMFLAGS --define \"_sourcedir `pwd`\" --define \"_builddir `pwd`/BUILD\" --define \"_rpmdir `pwd`/RPMS\" --define \"_srpmdir `pwd`/SRPMS\" *.spec"
	rpm -ba --target $TARGET --with system_libc --without uclibc $EXTRA_RPMFLAGS --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec
	# nodeps is necessary at this point because libc and friends aren't coming from packages yet
	sudo rpm --root $SYSROOT --ignorearch -Uvh --force --nodeps RPMS/*/*.rpm
	cd ..
done