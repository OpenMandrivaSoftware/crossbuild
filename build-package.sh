#!/bin/sh
set -x

if [ "$1" = "--target" -o "$1" = "-t" ]; then
	shift
	RPMTARGET="$1"
	shift
fi
[ -z "$RPMTARGET" ] && RPMTARGET=riscv64-linux

if [ -z "$1" ]; then
	echo "Specify package"
	exit 1
fi

FULLTARGET="$(rpm --target=$RPMTARGET -E %{_target_platform})"
SYSROOT=/usr/$FULLTARGET
if [ ! -d $SYSROOT ]; then
	echo "No sysroot for $FULLTARGET"
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
	echo "Running: rpmbuild -ba --target $RPMTARGET --without uclibc $EXTRA_RPMFLAGS --define \"_sourcedir `pwd`\" --define \"_builddir `pwd`/BUILD\" --define \"_rpmdir `pwd`/RPMS\" --define \"_srpmdir `pwd`/SRPMS\" *.spec"
	rpmbuild -ba --nodeps --target $RPMTARGET --without uclibc $EXTRA_RPMFLAGS --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec
	cd ..
done
