#!/bin/sh

if [ "$1" = "--target" -o "$1" = "-t" ]; then
	shift
	TARGET="$1"
	shift
fi
[ -z "$TARGET" ] && TARGET=x86_64-openmandriva-linux-musl
#[ -z "$TARGET" ] && TARGET=aarch64-mandriva-linux-gnu
#[ -z "$TARGET" ] && TARGET=armv7hf-mandriva-linux-gnu

if [ -z "$1" ]; then
	echo "Specify package"
	exit 1
fi

TARGET="`/usr/share/libtool/config/config.sub $TARGET`"
# Cache sudo credentials now so we don't end up prompting
# while the user is looking at something else...
sudo true

SYSROOT=/usr/$TARGET/sys-root
if [ ! -d $SYSROOT ]; then
	echo "No sysroot for $TARGET"
	exit 1
fi
SMP_MFLAGS="-j`getconf _NPROCESSORS_ONLN`"
[ "$SMP_MFLAGS" = "-j" ] && SMP_MFLAGS="-j4"

set -e

cd `dirname $0`
DIR=`pwd`

cd packages
for i in "$@"; do
	case $i in
	ncurses)
		# Depending on our target, we may not have an STL yet
		EXTRA_RPMFLAGS="--without cplusplus"
		;;
	mksh)
		EXTRA_RPMFLAGS="--with bin_sh"
		;;
	make)
		EXTRA_RPMFLAGS="--without guile"
		;;
	binutils)
		EXTRA_RPMFLAGS="--without gold"
		;;
	llvm)
		cat >$TARGET-c++ <<EOF
#!/bin/sh
exec clang++ -target $TARGET --sysroot=$SYSROOT -isysroot $SYSROOT -stdlib=libc++ -ccc-gcc-name $TARGET-g++ "\$@" -lc++ -lc++abi
EOF
		chmod +x $TARGET-c++
		sudo mv $TARGET-c++ /usr/bin
		EXTRA_RPMFLAGS="--with libcxx --without ocaml --with bootstrap --without ffi"
		;;
	*)
		EXTRA_RPMFLAGS=""
		;;
	esac
	rm -rf $i
	abf get openmandriva/$i
	cd $i
	abf fetch
	rm -rf BUILD RPMS SRPMS
	echo "Running: rpm -ba --target $TARGET --without uclibc $EXTRA_RPMFLAGS --define \"_sourcedir `pwd`\" --define \"_builddir `pwd`/BUILD\" --define \"_rpmdir `pwd`/RPMS\" --define \"_srpmdir `pwd`/SRPMS\" *.spec"
	rpm -ba --target $TARGET --without uclibc $EXTRA_RPMFLAGS --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec
	# nodeps is necessary at this point because libc and friends aren't coming from packages yet
	sudo rpm --root $SYSROOT --ignorearch -Uvh --force --nodeps RPMS/*/*.rpm
	cd ..
done
