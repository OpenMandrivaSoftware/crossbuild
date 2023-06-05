#!/bin/sh
set -x

if [ "$1" = "--target" -o "$1" = "-t" ]; then
	shift
	TARGET="$1"
	shift
fi
[ -z "$TARGET" ] && TARGET=riscv64-openmandriva-linux-gnu
#[ -z "$TARGET" ] && TARGET=x86_64-openmandriva-linux-musl
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

SYSROOT=/usr/$TARGET
if [ ! -d $SYSROOT ]; then
	echo "No sysroot for $TARGET"
	exit 1
fi
SMP_MFLAGS="-j`getconf _NPROCESSORS_ONLN`"
[ "$SMP_MFLAGS" = "-j" ] && SMP_MFLAGS="-j4"

set -e

cd `dirname $0`
DIR=`pwd`

mkdir -p packages
cd packages
for i in "$@"; do
	pkg="$i"

	EXTRA_RPMFLAGS=""
	while echo $pkg |grep -q :; do
		flag="$(echo $pkg |cut -d: -f2)"
		if [ "$(echo $flag |cut -b1)" = "-" ]; then
			EXTRA_RPMFLAGS="$EXTRA_RPMFLAGS --without $(echo $flag |cut -b2-)"
		else
			EXTRA_RPMFLAGS="$EXTRA_RPMFLAGS --with $flag"
		fi
		pkg="$(echo $(echo $pkg |cut -d: -f1):$(echo $pkg |cut -d: -f3-) | sed -e 's,:$,,')"
	done

	rm -rf $pkg
	git clone --depth 1 git@github.com:OpenMandrivaAssociation/$pkg
	cd $pkg
	[ -e .abf.yml ] && abf fetch
	rm -rf BUILD RPMS SRPMS
	echo "Running: rpmbuild -ba --target $TARGET --without uclibc $EXTRA_RPMFLAGS --define \"_sourcedir `pwd`\" --define \"_builddir `pwd`/BUILD\" --define \"_rpmdir `pwd`/RPMS\" --define \"_srpmdir `pwd`/SRPMS\" *.spec"
	rpmbuild -ba --nodeps --target $TARGET --without uclibc $EXTRA_RPMFLAGS --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec
	# nodeps is necessary at this point because libc and friends aren't coming from packages yet
	#sudo rpm --root $SYSROOT --ignorearch -Uvh --force --nodeps RPMS/*/*.rpm
	cd ..
done
