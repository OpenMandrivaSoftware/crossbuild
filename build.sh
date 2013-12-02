#!/bin/sh
TARGET="$1"
[ -z "$TARGET" ] && TARGET=aarch64-mandriva-linux-gnu
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

if [ "$LIBC" = "bionic" -a ! -d android ]; then
	mkdir android
	cd android
	git clone git://android.git.linaro.org/platform/bionic.git
	cd bionic
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ..
	git clone git://android.git.linaro.org/platform/build.git
	cd build
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ..
	mkdir -p device/linaro
	cd device/linaro
	git clone git://android.git.linaro.org/device/linaro/common.git
	cd common
	git checkout -b linaro-ics origin/linaro-ics
	cd ..
	git clone git://android.git.linaro.org/device/linaro/pandaboard.git
	cd pandaboard
	git checkout -b linaro-jb origin/linaro-jb
	cd ..
	cd ../..
	mkdir frameworks
	cd frameworks
	git clone git://android.git.linaro.org/platform/frameworks/native.git
	cd native
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	# All we need is tablet-dalvik-heap.mk - but opengl/tests/Android.mk's presence actually breaks things
	rm -rf opengl/tests
	cd ../..
	mkdir -p hardware/ti
	cd hardware/ti
	git clone git://android.git.linaro.org/platform/hardware/ti/omap4xxx
	cd omap4xxx
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ../../..
	mkdir system
	cd system
	git clone git://android.git.linaro.org/platform/system/core.git
	cd core
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ../..
	mkdir external
	cd external
	git clone git://android.git.linaro.org/platform/external/stlport.git
	cd stlport
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ..
	git clone git://android.git.linaro.org/platform/external/llvm.git
	cd llvm
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ..
	git clone git://android.git.linaro.org/platform/external/clang.git
	cd clang
	git checkout -b linaro_android_4.2.2 origin/linaro_android_4.2.2
	cd ..
	git clone git://android.git.linaro.org/platform/external/compiler-rt.git
	cd compiler-rt
	git checkout -b 4.2.2 android-4.2.2_r1
	cd ..
	git clone git://android.git.linaro.org/platform/external/safe-iop.git
	cd safe-iop
	git checkout -b 4.2.2 android-4.2.2_r1
	cd ..
	cd ..
	ln -sf build/core/root.mk Makefile
	cd ..
fi

sudo rm -rf /usr/$TARGET
sudo rm -rf $SYSROOT
sudo mkdir -p $SYSROOT
# Let's make life easier for things that hardcode FHS compliance
if [ "$USR" != "/usr" ]; then
	sudo ln -s `basename $USR` $SYSROOT/usr
fi

echo ========================================================================
echo binutils
echo ========================================================================
cd binutils/BUILD/*
rm -rf build ; mkdir build
cd build
if $GOLD; then
	GOLDFLAGS="--enable-ld --enable-gold=default"
else
	GOLDFLAGS="--enable-ld=default"
fi
../configure --prefix=/usr --target=$TARGET --with-sysroot=$SYSROOT $GOLDFLAGS --enable-plugins --enable-threads
make $SMP_MFLAGS
sudo make install
cd ../../../..
$GOLD && ( rm -rf ld.bfd ; mkdir ld.bfd ; ln -s $USR/bin/$TARGET-ld.bfd ld.bfd/$TARGET-ld ; rm -rf binutils.bfd ; mkdir binutils.bfd ; ln -s $USR/$TARGET/bin/* binutils.bfd ; ln -sf ld.bfd binutils.bfd/ld )


echo ========================================================================
echo bootstrap gcc
echo ========================================================================
cd gcc/BUILD/*
rm -rf build-stage1 ; mkdir build-stage1
cd build-stage1
# We build a C++ compiler because of Bionic's C++ malloc.
# We don't build libstdc++ because it needs libc headers.
../configure --prefix=/usr --target=$TARGET --with-sysroot=$SYSROOT --disable-multilib --disable-__cxa_atexit --disable-libmudflap --disable-libssp --disable-threads --disable-tls --disable-decimal-float --disable-libgomp --disable-libquadmath --disable-shared --disable-libstdc__-v3 --disable-sjlj-exceptions --disable-libitm --disable-libquadmath --enable-languages=c,c++ --with-newlib $GCCEXTRAARGS
make $SMP_MFLAGS
sudo make install
cd ../../../..


echo ========================================================================
echo kernel headers
echo ========================================================================
# Just the headers for now...
cd kernel/BUILD/kernel-*
make ARCH=$KERNELARCH CROSS_COMPILE=$TARGET- defconfig
make ARCH=$KERNELARCH CROSS_COMPILE=$TARGET- prepare0 prepare1 prepare2 prepare3
sudo make ARCH=$KERNELARCH CROSS_COMPILE=$TARGET- INSTALL_HDR_PATH=$SYSROOT$USR headers_install
cd ../../..

echo ========================================================================
echo libc headers
echo ========================================================================
case $LIBC in
glibc)
	# (e)glibc doesn't like being built with gold
	#$GOLD && OLDPATH="$PATH" && export PATH="$DIR"/ld.bfd:$PATH && BU="--with-binutils=$DIR/binutils.bfd"
	cd glibc/BUILD/*
	sudo rm -rf build ; mkdir build
	cd build

	which $TARGET-ld
	$TARGET-ld --version

	../configure --prefix=$USR --target=$TARGET --host=$TARGET --with-sysroot=$SYSROOT --enable-add-ons=ports,nptl,libidn --with-headers=$SYSROOT$USR/include --disable-profile --without-gd --without-cvs --enable-omitfp --enable-oldest-abi=2.12 --enable-kernel=2.6.24 --enable-experimental-malloc --disable-systemtap --enable-bind-now --disable-selinux $BU
	sudo make $SMP_MFLAGS install-headers install_root=$SYSROOT install-bootstrap-headers=yes
	sudo mkdir -p $SYSROOT$USR/lib
	make $SMP_MFLAGS csu/subdir_lib
	sudo cp csu/crt1.o csu/crti.o csu/crtn.o $SYSROOT$USR/lib/
	sudo $TARGET-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o $SYSROOT$USR/lib/libc.so
	cd ../../../..
#	$GOLD && export PATH="$OLDPATH"
	;;
uclibc)
	cd uClibc/BUILD/*
	make ARCH=$ARCH defconfig
	# Let's make it the system libc...
	sed -i -e "s,^RUNTIME_PREFIX=.*,RUNTIME_PREFIX=\"$USR\",g" .config
	sed -i -e "s,^DEVEL_PREFIX=.*,DEVEL_PREFIX=\"$USR\",g" .config
	sed -i -e "s,^CROSS_COMPILER_PREFIX=.*,CROSS_COMPILER_PREFIX=\"$TARGET-\",g" .config
	# And enable all we need to build gcc
	sed -i -e 's,^# UCLIBC_HAS_FENV is not set,UCLIBC_HAS_FENV=y,g' .config
	#sed -i -e 's,^HAS_NO_THREADS=y,# HAS_NO_THREADS is not set,g' .config
	#sed -i -e '/HAS_NO_THREADS/iUCLIBC_HAS_THREADS_NATIVE=y\nUCLIBC_HAS_THREADS=y\nUCLIBC_HAS_TLS=y\n# PTHREADS_DEBUG_SUPPORT is not set' .config
	find include -type l |xargs rm || :
	make ARCH=$ARCH realclean V=2
	make ARCH=$ARCH oldconfig
	make ARCH=$ARCH
	sudo make ARCH=$ARCH install DESTDIR=$SYSROOT
	# The next step needs pthread headers, but not actual support
	sudo cp libpthread/nptl/sysdeps/pthread/pthread.h $SYSROOT$USR/include/
	sudo cp libpthread/nptl/sysdeps/unix/sysv/linux/$ARCH/bits/pthreadtypes.h $SYSROOT$USR/include/bits/
	cd ../../..
	;;
bionic)
	for i in libc/include libc/arch-$ARCH/include libc/kernel/common libc/kernel/arch-$ARCH libm/include; do
		sudo cp -a android/bionic/$i/* $SYSROOT$USR/include/
	done
	# We need STLport too, Android doesn't do libstdc++
	sudo mkdir -p $SYSROOT$USR/include/libstdc++
	sudo cp -a android/bionic/libstdc++/include $SYSROOT$USR/include/libstdc++/
	sudo cp -a android/external/stlport/stlport $SYSROOT$USR/include/
	# Make them match the include directory structure we're building
	sudo sed -i -e 's,\.\./include/header,../header,g;s,usr/include,system/include,g' $SYSROOT$USR/include/stlport/stl/config/_android.h
	# And don't insist on -DANDROID when gcc already defines __ANDROID__ for us
	sudo sed -i -e 's,defined (ANDROID),defined (ANDROID) || defined (__ANDROID__),g' $SYSROOT$USR/include/stlport/stl/config/_system.h

	cd android
	make TARGET_TOOLS_PREFIX=/usr/bin/$TARGET- TARGET_PRODUCT=pandaboard \
		out/target/product/pandaboard/obj/lib/crtbegin_dynamic.o \
		out/target/product/pandaboard/obj/lib/libc.so \
		out/target/product/pandaboard/obj/lib/libdl.so \
		out/target/product/pandaboard/obj/lib/libm.so
	sudo mkdir -p $SYSROOT$USR/lib
	sudo cp out/target/product/*/obj/lib/* $SYSROOT$USR/lib/
	# Android's pthread bits are built into bionic libc -- but lots of traditional
	# Linux configure scripts and Makefiles just hardcode that there's a -lpthread...
	# Let's accomodate them
	touch dummy.c
	$TARGET-gcc -O2 -o dummy.o -c dummy.c
	sudo $TARGET-ar cru $SYSROOT$USR/lib/libpthread.a dummy.o
	rm -f dummy.[co]
	cd ..
	;;
esac

echo ========================================================================
echo stage 2 compiler
echo ========================================================================
# GCC, step 2...
cd gcc/BUILD/*
rm -rf build-stage2 ; mkdir build-stage2
cd build-stage2
../configure --prefix=$USR --target=$TARGET --with-sysroot=$SYSROOT --disable-libssp --disable-libgomp --disable-libmudflap --disable-libquadmath --enable-languages=c --disable-multilib $GCCEXTRAARGS
make $SMP_MFLAGS
sudo make $SMP_MFLAGS install
cd ../../../..

case $LIBC in
glibc)
	echo ========================================================================
	echo libc
	echo ========================================================================
	# real (e)glibc
	# (e)glibc doesn't like being built with gold
#	$GOLD && OLDPATH="$PATH" && export PATH="$DIR"/ld.bfd:$PATH && BU="--with-binutils=$DIR/binutils.bfd"
	$GOLD && GLIBC_LDFLAGS="-fuse-ld=bfd"
	cd glibc/BUILD/*/libc
	rm -rf build1 ; mkdir build1
	cd build1
	../configure --prefix=$USR --target=$TARGET --host=$TARGET --with-sysroot=$SYSROOT --enable-add-ons=ports,nptl,libidn --with-headers=$SYSROOT$USR/include --disable-profile --without-gd --without-cvs --enable-omitfp --enable-oldest-abi=2.12 --enable-kernel=2.6.24 --enable-experimental-malloc --disable-systemtap --enable-bind-now $BU
	make $SMP_MFLAGS LDFLAGS="$GLIBC_LDFLAGS" || make $SMP_MFLAGS LDFLAGS="$GLIBC_LDFLAGS"
	sudo make install install_root=$SYSROOT LDFLAGS="$GLIBC_LDFLAGS"
	cd ../../../..
#	$GOLD && PATH="$OLDPATH"
	;;
uclibc)
	cd uClibc/BUILD/*
	make ARCH=$ARCH defconfig
	# Let's make it the system libc...
	sed -i -e "s,^RUNTIME_PREFIX=.*,RUNTIME_PREFIX=\"$USR\",g" .config
	sed -i -e "s,^DEVEL_PREFIX=.*,DEVEL_PREFIX=\"$USR\",g" .config
	sed -i -e "s,^CROSS_COMPILER_PREFIX=.*,CROSS_COMPILER_PREFIX=\"$TARGET-\",g" .config
	# Enable wanted/needed features
	sed -i -e 's,^# UCLIBC_HAS_FENV is not set,UCLIBC_HAS_FENV=y,g' .config
	sed -i -e 's,^# UCLIBC_HAS_WCHAR is not set,UCLIBC_HAS_WCHAR=y,g' .config
	# Needed by libstdc++ (tmpnam in <cstdio>)
	sed -i -e 's,^# UCLIBC_SUSV4_LEGACY is not set,UCLIBC_SUSV4_LEGACY=y,g' .config
	# But we don't need all the cruft
	echo '# UCLIBC_HAS_FTW is not set' >>.config
	# Enable threading
	sed -i -e 's,^HAS_NO_THREADS=y,# HAS_NO_THREADS is not set,g' .config
	sed -i -e '/HAS_NO_THREADS/iUCLIBC_HAS_THREADS_NATIVE=y\nUCLIBC_HAS_THREADS=y\nUCLIBC_HAS_TLS=y\n# PTHREADS_DEBUG_SUPPORT is not set' .config
	find include -type l |xargs rm || :
	make ARCH=$ARCH realclean V=2
	rm -f extra/locale/gen_ldc extra/locale/gen_wc8bit extra/locale/gen_wctype
	make ARCH=$ARCH oldconfig
	make ARCH=$ARCH
	sudo make ARCH=$ARCH install DESTDIR=$SYSROOT
	sudo cp include/pthread.h $SYSROOT$USR/include/
	sudo cp include/bits/pthreadtypes.h $SYSROOT$USR/include/bits/
	cd ../../..
	;;
bionic)
	cd android
	make TARGET_TOOLS_PREFIX=/usr/bin/$TARGET- TARGET_PRODUCT=pandaboard \
		out/target/product/pandaboard/obj/lib/libstdc++.so
	ONE_SHOT_MAKEFILE=external/stlport/Android.mk make all_modules TARGET_TOOLS_PREFIX=/usr/bin/$TARGET- TARGET_PRODUCT=pandaboard
	sudo cp out/target/product/*/obj/lib/*stl* $SYSROOT$USR/lib/
	sudo cp out/target/product/*/obj/lib/*stdc* $SYSROOT$USR/lib/
	cd ..
	;;
esac

echo ========================================================================
echo stage 3 compiler
echo ========================================================================
# Real GCC
cd gcc/BUILD/*
rm -rf build-stage3 ; mkdir build-stage3
cd build-stage3
../configure --target=$TARGET --prefix=$USR --with-sysroot=$SYSROOT --enable-__cxa_atexit --disable-libssp --disable-libmudflap --disable-libquadmath --disable-multilib --disable-libgomp --enable-languages=c,c++,ada,objc,obj-c++,lto $GCCEXTRAARGS
make $SMP_MFLAGS
sudo make $SMP_MFLAGS install
cd ../../../..

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

if echo $TARGET |grep -qE '(64|s390x|ia32e)-'; then
	echo >>macros
	echo '%_lib	lib64' >>macros
	# Since we aren't building multi-arch sysroots (for now),
	# make lib and lib64 the same -- compilers tend not to
	# look in lib64 inside a sysroot (e.g. aarch64, gcc 4.7.x)
sudo	ln -s lib $SYSROOT/lib64
sudo	ln -s lib $SYSROOT/$USR/lib64
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
for i in kernel filesystem setup ncurses bash coreutils; do
	abf get openmandriva/$i
	cd $i
	abf fetch
	rm -rf BUILD RPMS SRPMS
	rpm -ba --target $TARGET --without uclibc --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec
	# nodeps is necessary at this point because libc and friends aren't coming from packages yet
	sudo rpm --root $SYSROOT --ignorearch -Uvh --force --nodeps RPMS/*/*.rpm
	cd ..
done
