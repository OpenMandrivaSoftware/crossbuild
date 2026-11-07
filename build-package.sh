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

EXITCODE=0
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

# find-debuginfo LTO rewrite of static .a files needs disk, not tmpfs /tmp
if [ -z "$TMPDIR" ] || [ "$TMPDIR" = /tmp ]; then
	TMPDIR="$DIR/.tmp"
	mkdir -p "$TMPDIR"
	export TMPDIR
fi

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
	if [ -d "$DIR/patches/$pkg" ]; then
		for p in "$DIR/patches/$pkg"/*; do
			[ -f "$p" ] || continue
			echo "Applying local patch $p"
			patch -p1 < "$p"
		done
	fi
	[ -e .abf.yml ] && abf fetch
	rm -rf BUILD RPMS SRPMS
	# --target before --load: otherwise %%cross_compiling is baked as 0
	# while the macros file is parsed.
	echo "Running: rpmbuild --target $RPMTARGET --load $DIR/macros.cross-pkgconfig -ba --without uclibc $EXTRA_RPMFLAGS --define \"_sourcedir `pwd`\" --define \"_builddir `pwd`/BUILD\" --define \"_rpmdir `pwd`/RPMS\" --define \"_srpmdir `pwd`/SRPMS\" *.spec"
	# Log through a file, not a pipe into tee. A build step that
	# backgrounds a process on inherited stdout (mkcomposecache's
	# xbiff) holds a pipe open, tee never sees EOF, and this script
	# sits there after the packages have already been written.
	# The log has to exist before tail starts: the redirect is applied
	# in the rpmbuild child, and this shell continues as soon as that
	# child is forked. tail otherwise exits with "no files remaining"
	# and the live log is lost.
	(
		set +e
		: > build.log
		rpmbuild --target $RPMTARGET --load "$DIR/macros.cross-pkgconfig" -ba --nodeps --without uclibc $EXTRA_RPMFLAGS --define "_sourcedir `pwd`" --define "_builddir `pwd`/BUILD" --define "_rpmdir `pwd`/RPMS" --define "_srpmdir `pwd`/SRPMS" *.spec >>build.log 2>&1 &
		rpid=$!
		tail -n +1 --pid="$rpid" -f build.log &
		tpid=$!
		wait "$rpid"
		rc=$?
		# tail --pid should exit on its own. A zombie still answers
		# kill -0, so check /proc and do not sleep once tail is done.
		# Bound the wait so a follower cannot wedge the driver the way
		# the tee pipe did.
		i=0
		while [ "$i" -lt 5 ]; do
			[ -d "/proc/$tpid" ] || break
			grep -q '^State:[[:space:]]*Z' "/proc/$tpid/status" 2>/dev/null && break
			sleep 1
			i=$((i+1))
		done
		kill "$tpid" 2>/dev/null
		wait "$tpid"
		exit "$rc"
	)
	EXITCODE=$?
	cd ..
done
exit $EXITCODE
