#!/bin/sh

echo '--> mdv-scripts/build-packages: build.sh'

# rhel example:
git_project_address="https://abf.rosalinux.ru/openmandriva/$1.git"
# commit_hash="fbb2549e44d97226fea6748a4f95d1d82ffb8726"
#git_project_address="$GIT_PROJECT_ADDRESS"
git_armock_addres="${git_project_address%rosalinux.ru*}rosalinux.ru/cross/arm_build.git"
commit_hash="$COMMIT_HASH"

uname="$UNAME"
email="$EMAIL"
platform_name="$PLATFORM_NAME"
#platform_arch="$ARCH"
platform_arch="armv7l"
#platform_arch="armv7nhl_omp3"



echo $git_project_address | awk '{ gsub(/\:\/\/.*\:\@/, "://[FILTERED]@"); print }'
echo 'comit hash'
echo $commit_hash
echo $uname
echo $email

archives_path="/home/fedya/archives"
results_path="/home/fedya/results"
tmpfs_path="/home/fedya/tmpfs"
project_path="$tmpfs_path/project"
project_armmock_path="$tmpfs_path/project_arm"
cross_chroot="/home/fedya/cross/"
rpm_build_script_path=`pwd`

rm -rf $archives_path $results_path $tmpfs_path $project_path
mkdir  $archives_path $results_path $tmpfs_path $project_path

# Mount tmpfs
#sudo mount -t tmpfs tmpfs -o size=30000M,nr_inodes=10M $tmpfs_path

#get chroot
#wget http://abf-downloads.rosalinux.ru/r0mik_personal/cross.tgz -P $tmpfs_path
#extract chroot
#sudo tar xfzp $tmpfs_path/cross.tgz -C  $tmpfs_path

#fix bug server certificate verification failed
export GIT_SSL_NO_VERIFY=1

# Download project
# Fix for: 'fatal: index-pack failed'
git config --global core.compression -1
git clone $git_project_address $project_path
cd $project_path
git submodule update --init
git remote rm origin
git checkout $commit_hash

#Download build script

#git clone $git_armock_addres $project_armmock_path
#sudo cp $project_armmock_path/armock.emb.14.05.2013 $cross_chroot/rootfs/usr/local/bin/armock
#sudo cp -R $project_armmock_path/sysroot2/ $cross_chroot/rootfs/usr/local/bin/






# TODO: build changelog

# Downloads extra files by .abf.yml
ruby $rpm_build_script_path/abf_yml.rb -p $project_path

# Remove .git folder
rm -rf $project_path/.git
rm -rf $project_armock_path/.git



# Check count of *.spec files (should be one)
cd $project_path
x=`ls -1 | grep '.spec$' | wc -l | sed 's/^ *//' | sed 's/ *$//'`
spec_name=`ls -1 | grep '.spec$'`
if [ $x -eq '0' ] ; then
  echo '--> There are no spec files in repository.'
  exit 1
else
  if [ $x -ne '1' ] ; then
    echo '--> There are more than one spec file in repository.'
    exit 1
  fi
fi

# create SPECS folder and move *.spec
sudo mkdir -p  $cross_chroot/rootfs/root/rpmbuild/SPECS
sudo mv $project_path/*.spec $cross_chroot/rootfs/root/rpmbuild/SPECS/

#create SOURCES folder and move src
sudo mkdir -p $cross_chroot/rootfs/root/rpmbuild/SOURCES/
sudo mv $project_path/* $cross_chroot/rootfs/root/rpmbuild/SOURCES/
#echo 'get git project files in chroot'
#sudo ls $cross_chroot/rootfs/root/rpmbuild/SOURCES/
#sudo ls $cross_chroot/rootfs/root/rpmbuild/SPECS/


# Init folders for building src.rpm
cd $archives_path
src_rpm_path=$archives_path/SRC_RPM
mkdir $src_rpm_path

rpm_path=$archives_path/RPM
mkdir $rpm_path


config_name="openmandriva-$platform_arch.cfg"
config_dir=/etc/mock-urpm/
sudo echo "armv7l-mandriva-linux-gnueabi" >> /etc/rpm/platform

# Init config file
default_cfg=$rpm_build_script_path/configs/default.cfg
cp $rpm_build_script_path/configs/$config_name $default_cfg
media_list=/home/fedya/container/media.list

echo "config_opts['macros']['%packager'] = '$uname <$email>'" >> $default_cfg

echo 'config_opts["urpmi_media"] = {' >> $default_cfg
first='1'
while read CMD; do
	name=`echo $CMD | awk '{ print $1 }'`
	url=`echo $CMD | awk '{ print $2 }'`
	if [ "$first" == '1' ] ; then
		echo "\"$name\": \"$url\"" >> $default_cfg
		first=0
	else
		echo ", \"$name\": \"$url\"" >> $default_cfg
	fi
done < $media_list
echo '}' >> $default_cfg


sudo rm -rf $config_dir/default.cfg
sudo ln -s $default_cfg $config_dir/default.cfg

# sleep 99999999999

#Build src.rpm in cross chroot

#echo '--> Mount in arm chroot'

#echo '--> Mount in arm chroot test!'
#sudo ls /proc/sys/fs/binfmt_misc
#mount
#echo '--> Mount in arm chroot end test'
echo "--> Create chroot"
sudo /usr/sbin/urpmi.addmedia --urpmi-root /home/fedya/cross/rootfs/ local-arm file://home/fedya/repo/ && sudo /usr/sbin/urpmi --noscripts --no-suggests --no-verify-rpm --ignorearch --root /home/fedya/cross/rootfs/ --urpmi-root /home/fedya/cross/rootfs/ --auto basesystem-minimal rpm-build make urpmi
sudo cp /home/fedya/arm-scripts/build-packages/qemu* /home/fedya/cross/rootfs/usr/bin/
sudo cp /etc/resolv.conf /home/fedya/cross/rootfs/etc/resolv.conf
sudo mkdir -p /home/fedya/cross/rootfs/home/fedya/repo
sudo mount -obind /dev/ /home/fedya/cross/rootfs/dev 
sudo mount -obind /proc/ /home/fedya/cross/rootfs/proc
sudo mount -obind /sys/ /home/fedya/cross/rootfs/sys
#i use local repo and mount it
# u can use http or ftp
sudo mount -obind /home/fedya/repo/ /home/fedya/cross/rootfs/home/fedya/repo
echo "-->> Chroot is done"
sudo chmod -R 777 $cross_chroot/rootfs/root/rpmbuild
sudo chown -R root:root $cross_chroot/rootfs/root/rpmbuild
sudo chroot $cross_chroot/rootfs/ /bin/bash --init-file /etc/bashrc -i  -c "/usr/bin/rpmbuild -bs -v --nodeps  /root/rpmbuild/SPECS/$spec_name && exit"
rc=$?


#sudo  build.py  -s $spec_name --sources $tmpfs_path/SOURCES/ --o $src_rpm_path 
# Save exit code

echo '--> Done.'

# Move all logs into the results dir.
function move_logs {
  prefix=$2
  for file in $1/*.log ; do
    name=`basename $file`
    if [[ "$name" =~ .*\.log$ ]] ; then
      echo "--> mv $file $results_path/$prefix-$name"
      mv $file "$results_path/$prefix-$name"
    fi
  done
}


#!!! 
#move_logs $src_rpm_path 'src-rpm'

# Check exit code after build
if [ $rc != 0 ] ; then
  echo '--> Build failed: mock-urpm encountered a problem.'
  exit 1
fi

# Build rpm
src_rpm_name=`sudo ls $cross_chroot/rootfs/root/rpmbuild/SRPMS/ -1 | grep 'src.rpm'`
#echo 'get src_rpm name'
echo $src_rpm_name
echo '--> Building rpm...'
#sudo chroot $cross_chroot/rootfs/ /bin/bash --init-file /etc/bashrc -i  -c "armock -t $platform_arch -p /root/rpmbuild/SRPMS/$src_rpm_name"
sudo chroot $cross_chroot/rootfs/ /bin/bash --init-file /etc/bashrc -i -c "urpmi --buildrequires --ignorearch --auto --no-verify-rpm /root/rpmbuild/SPECS/$spec_name && exit"
sudo chroot $cross_chroot/rootfs/ /bin/bash --init-file /etc/bashrc -i -c "/usr/bin/rpmbuild -ba -v /root/rpmbuild/SPECS/$spec_name"


#mock $src_rpm_name --resultdir $rpm_path -v --no-cleanup
# Save exit code
rc=$?
echo '--> Done.'

echo '--> Get result.'
sudo sh -c "mv  $cross_chroot/rootfs/root/rpmbuild/RPMS/$platform_arch/*.rpm /home/fedya/rpms/"
sudo sh -c "mv  $cross_chroot/rootfs/root/rpmbuild/RPMS/noarch/*.rpm /home/fedya/rpms/"
sudo sh -c "mv  $cross_chroot/rootfs/root/rpmbuild/SRPMS/*.rpm $results_path/"

echo '--> Done.'
sudo umount /home/fedya/cross/rootfs/dev 
sudo umount /home/fedya/cross/rootfs/proc
sudo umount /home/fedya/cross/rootfs/sys
sudo umount -l /home/fedya/cross/rootfs/home/fedya/repo
sudo rm -f /etc/rpm/platform

# Save results
# mv $tmpfs_path/SPECS $archives_path/
# mv $tmpfs_path/SOURCES $archives_path/

# Remove src.rpm from RPM dir
src_rpm_name=`ls -1 $rpm_path/ | grep 'src.rpm$'`
if [ "$src_rpm_name" != '' ] ; then
  rm $rpm_path/*.src.rpm
fi

r=`head -1 $config_dir/default.cfg |
  sed -e "s/config_opts//g" |
  sed -e "s/\[//g" |
  sed -e "s/\]//g" |
  sed -e "s/root//g" |
  sed -e "s/=//g" |
  sed -e "s/'//g"|
  sed -e "s/ //g"`
chroot_path=$tmpfs_path/$r/root
echo '--> Checking internet connection...'
sudo chroot $chroot_path ping -c 1 google.com

# Tests
test_log=$results_path/tests.log
test_root=$tmpfs_path/test-root
test_code=0
#rpm -qa --queryformat "%{name}-%{version}-%{release}.%{arch}.%{disttag}%{distepoch}\n" --root $chroot_path >> $results_path/rpm-qa.log
#if [ $rc == 0 ] ; then
#  ls -la $rpm_path/ >> $test_log
#  sudo yum -v --installroot=$chroot_path install -y $rpm_path/*.rpm >> $test_log 2>&1
#  test_code=$?
#  rm -rf $test_root
#fi

#if [ $rc == 0 ] && [ $test_code == 0 ] ; then
  #ls -la $src_rpm_path/ >> $test_log
#fi

#if [ $rc != 0 ] || [ $test_code != 0 ] ; then
#  tree $chroot_path/builddir/build/ >> $results_path/chroot-tree.log
#fi

# Umount tmpfs
cd /
sudo umount $tmpfs_path
rm -rf $tmpfs_path
sudo rm -rf /home/fedya/cross/rootfs/

#move_logs $rpm_path 'rpm'

# Check exit code after build
if [ $rc != 0 ] ; then
  echo '--> Build failed!!!'
  exit 1
fi

# Generate data for container
sudo apt-get install -qq -y rpm
c_data=$results_path/container_data.json
echo '[' > $c_data
for rpm in $results_path/*.rpm $results_path/*.src.rpm ; do
  name=`rpm -qp --queryformat %{NAME} $rpm`
  if [ "$name" != '' ] ; then
    fullname=`basename $rpm`
    version=`rpm -qp --queryformat %{VERSION} $rpm`
    release=`rpm -qp --queryformat %{RELEASE} $rpm`
    sha1=`sha1sum $rpm | awk '{ print $1 }'`

    echo '{' >> $c_data
    echo "\"fullname\":\"$fullname\","  >> $c_data
    echo "\"sha1\":\"$sha1\","          >> $c_data
    echo "\"name\":\"$name\","          >> $c_data
    echo "\"version\":\"$version\","    >> $c_data
    echo "\"release\":\"$release\""     >> $c_data
    echo '},' >> $c_data
  fi
done
# Add '{}'' because ',' before
echo '{}' >> $c_data
echo ']' >> $c_data
ls -l $results_path/

# Move all rpms into results folder
echo "--> mv $rpm_path/*.rpm $results_path/"
mv $rpm_path/*.rpm $results_path/
echo "--> mv $src_rpm_path/*.rpm $results_path/"
mv $src_rpm_path/*.rpm $results_path/

# Remove archives folder
rm -rf $archives_path

# Check exit code after testing
if [ $test_code != 0 ] ; then
  echo '--> Test failed, see: tests.log'
  exit 5
fi
echo '--> Build has been done successfully!'
exit 0
