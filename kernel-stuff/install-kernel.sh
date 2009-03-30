#!/bin/bash
########################################################################
####  Script Name:  install-kernel.sh - installer for archived kernels
####  version: 2.0.0
####  Date: March 30 2009
########################################################################
####  Script is based on kelmo and slh's old zip file kernel installer. 
####  Copyright (C) 2006-2008: Kel Modderman Stefan Lippers-Hollmann (sidux project)
####  Subsequent changes: copyright (C) 2008-2009: Harald Hope
####
####  This program is free software; you can redistribute it and/or modify it under
####  the terms of the GNU General Public License 2 as published by the Free Software
####  Foundation.
####
####  This program is distributed in the hope that it will be useful, but WITHOUT
####  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
####  FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
####
####  http://www.gnu.org/licenses/old-licenses/gpl-2.0.html
########################################################################
####  NOTE: kernel names are upgraded automatically for each new archive

########################################################################
#### VARIABLES
########################################################################
LINE='--------------------------------------------------------------------'
## set core variables: 
# make this match version kernel was built with, can be overridden with -g in dsl
GCC_VERSION='4.3'
# VER will be set dynamically by dsl
VER="2.6.24"
SCRIPT_NAME=$( basename $0)
UDEV_CONFIG_SIDUX='0.5.0'

# initialize globals
APT_TYPE=''

########################################################################
####  FUNCTIONS
########################################################################

### -------------------------------------------------------------------
### Utilities
### -------------------------------------------------------------------

# args: $1 - error number; $2 optional, extra error args
error_handler()
{
	local message=''

	case $1 in
		1)	message="$SCRIPT_NAME must be run as root."
			;;
		2)	message="/boot/vmlinuz-$VER already exists."
			;;
		3)	message="Kernel file linux-image-$VER failed to install correctly.\nPlease try to find out what went wrong with the install process."
			;;
	esac

	echo -e "Error $1: $message" >&2
	echo "Unable to continue. Exiting script now." >&2
	exit $1
}

# Returns null if package is not available in user system apt.
# args: $1 - package to test; $2 c/i
check_package_status()
{
	local packageVersion='' statusType='Candidate:'

	case $2 in
		c)	statusType='Candidate:'
			;;
		i)	statusType='Installed:'
			;;
	esac

	LC_ALL= LC_CTYPE= LC_MESSAGES= LANG= packageVersion=$( apt-cache policy $1 2>/dev/null | grep -i "$statusType" | cut -d ':' -f 2-4 | cut -d ' ' -f2 | grep -iv '\(none\)' )

	echo $packageVersion
}

### -------------------------------------------------------------------
### Install preparation
### -------------------------------------------------------------------

start_up_tests()
{
	echo $LINE
	echo 'Running initial kernel install startup tests and preparation...'
	if [ "$( id -u )" -ne 0 ]; then
		if [ -x "$( which su-to-root )" ];then
			exec su-to-root -c "$0"
		else
			error_handler 1
		fi
	fi
	
	if [ -e "/boot/vmlinuz-$VER" ]; then
		error_handler 2
	fi
	echo 'Startup tests passed. Continuing...'
}

set_script_data()
{
	# in case user is running aptitude
	if [ -f /etc/smxi.conf ];then
		APT_TYPE=$( awk -F '=' '
		/apt-type/ {
			if ( $2 == "apt-get" || $2 == "aptitude" ) {
				print $2
			}
		}' /etc/smxi.conf ) 
	fi
	if [ -z "$APT_TYPE" ];then
		APT_TYPE='apt-get'
	fi
}

set_kernel_img_conf()
{
	# ensure /etc/kernel-img.conf is configured with correct settings
	# - fix path to update-grub
	# - make sure "do_initrd = Yes"
	if [ -w /etc/kernel-img.conf ]; then
		echo -n 'Checking /etc/kernel-img.conf...'
	
		sed -i -e "s/\(postinst_hook\).*/\1\ \=\ \\/usr\\/sbin\\/update-grub/" \
			-e "s/\(postrm_hook\).*/\1\ \=\ \\/usr\\/sbin\\/update-grub/" \
			-e "s/\(do_initrd\).*/\1\ \=\ Yes/" \
			-e "/ramdisk.*mkinitrd\\.yaird/d" \
				/etc/kernel-img.conf
	
		if ! grep -q do_initrd /etc/kernel-img.conf; then
			echo "do_initrd = Yes" >> /etc/kernel-img.conf
		fi
	
		echo 'done.'
	else
		echo -n 'WARNING: /etc/kernel-img.conf is missing, creating file with defaults...'
		cat > /etc/kernel-img.conf <<EOF
do_bootloader = No
postinst_hook = /usr/sbin/update-grub
postrm_hook   = /usr/sbin/update-grub
do_initrd     = Yes
EOF
		echo 'done.'
	fi
}

check_script_dependencies()
{
	local installDependencies='' packageVersion=''
	
	# install important dependencies before attempting to install kernel
	if [ ! -x /usr/bin/gcc-$GCC_VERSION ];then
		installDependencies="$installDependencies gcc-$GCC_VERSION"
	fi
	if [ ! -x /usr/sbin/update-initramfs ];then
		installDependencies="$installDependencies initramfs-tools"
	fi
	
	# take care to install b43-fwcutter, if bcm43xx-fwcutter is already installed
	if dpkg -l bcm43xx-fwcutter 2>/dev/null | grep -q '^[hi]i' || [ -e /lib/firmware/bcm43xx_pcm4.fw ]; then
		dpkg -l b43-fwcutter 2>/dev/null | grep -q '^[hi]i' || installDependencies="$installDependencies b43-fwcutter"
	fi
	
	# make sure udev-config-sidux is up to date
	# - do not blacklist b43, we need it for kernel >= 2.6.23
	# - make sure to install the IEEE1394 vs. FireWire "Juju" blacklist
	if [ -n "$( check_package_status 'udev-config-sidux' 'c' )" ];then
		if [ -r /etc/modprobe.d/sidux ] || [ -r /etc/modprobe.d/ieee1394 ] || [ -r /etc/modprobe.d/mac80211 ]; then
			packageVersion=$(dpkg -l udev-config-sidux 2>/dev/null | awk '/^[hi]i/{print $3}')
			dpkg --compare-versions ${packageVersion:-0} lt $UDEV_CONFIG_SIDUX
			if [ "$?" -eq 0 ]; then
				installDependencies="$installDependencies udev-config-sidux"
			fi
		else
			installDependencies="$installDependencies udev-config-sidux"
		fi
	fi
	if [ -z "$( check_package_status 'sidux-scripts' 'i' )" -a -n "$( check_package_status 'sidux-scripts' 'c' )" ];then
		installDependencies="$installDependencies sidux-scripts"
	fi
	
	# install kernel, headers, documentation and any extras that were detected
	if [ -n "$installDependencies" ]; then
		echo $LINE
		echo 'Installing missing applications for kernel install.'
		$APT_TYPE update
		$APT_TYPE --assume-yes install $installDependencies
	fi
}

set_resume_partition()
{
	if [ -n "$( check_package_status 'sidux-scripts' 'i' )" ];then
		# check resume partition configuration is valid
		if [ -x /usr/sbin/get-resume-partition ]; then
			packageVersion=$( dpkg -l sidux-scripts 2>/dev/null | awk '/^[hi]i/{print $3}' )
			dpkg --compare-versions ${packageVersion:-0} ge 0.1.38
			if [ "$?" -eq 0 ]; then
				get-resume-partition
			fi
		fi
	fi
}

### -------------------------------------------------------------------
### Primary Kernel Installer
### -------------------------------------------------------------------

install_kernel_debs()
{
	# add linux-image and linux-headers to the install lists
	# the order here is critical, common is a dependency
	local package='' linuxHeadersAllArch='' linuxHeadersAll=''
	local linuxImage=$( ls linux-image-$VER*.deb 2> /dev/null )
	local linuxHeadersCommon=$( ls linux-headers-*-common*.deb 2> /dev/null )
	local linuxHeadersMain=$( ls linux-headers-*.deb 2> /dev/null | grep -v '\-all' )
	# linuxHeadersAllArch=$( ls linux-headers-*-all-*.deb 2> /dev/null )
	# linuxHeadersAll=$( ls linux-headers-*-all_*.deb 2> /dev/null )
	local linuxKbuild=$( ls linux-kbuild-2.6*.deb 2> /dev/null )
	local kernelPackages="$linuxImage $linuxHeadersCommon $linuxHeadersMain $linuxHeadersAllArch $linuxHeadersAll $linuxKbuild"
	local installedPackages=''
	
	echo $LINE
	echo 'Installing with dpkg -i kernel deb files now...'
	echo 'Install directory: ' $( pwd )
	# install the main kernel debs
	for package in $kernelPackages
	do
		echo $LINE
		echo "Installing archived kernel deb package: $package"
		dpkg -i $package
		installedPackages="$installedPackages $package"
	done
	# get these into system for aptitude
	if [ "$APT_TYPE" == 'aptitude' -a -n "$installedPackages" ];then
		echo "Installing kernel packages with $APT_TYPE to enter them into the $APT_TYPE database now..."
		$APT_TYPE install $installedPackages
	fi
	
	# something went wrong, allow apt an attempt to fix it
	if [ "$?" -ne 0 ]; then
		if [ -e "/boot/vmlinuz-$VER" ];then
			apt-get --fix-broken install
		else
			if [ -x /usr/sbin/update-grub ];then
				update-grub
			fi
			error_handler 3
		fi
	fi
}

post_kernel_install_steps()
{
	echo $LINE
	echo -n 'Running post kernel install steps...'
	# we do need an initrd
	if [ ! -f "/boot/initrd.img-$VER" ];then
		update-initramfs -k "$VER" -c
	fi
	
	# set new kernel as default
	if [ -L /boot/vmlinuz ];then
		rm -f /boot/vmlinuz
	fi
	if [ -L /boot/initrd.img ];then
		rm -f /boot/initrd.img
	fi
	if [ -L /boot/System.map ];then
		rm -f /boot/System.map
	fi
	if [ -L /vmlinuz ];then
		ln -fs "boot/vmlinuz-$VER" /vmlinuz
	fi
	if [ -L /initrd.img ];then
		ln -fs "boot/initrd.img-$VER" /initrd.img
	fi
	# in case we just created an initrd, update menu.lst
	if [ -x /usr/sbin/update-grub ]; then
		update-grub
	fi
	# set symlinks to the kernel headers
	ln -fs "linux-headers-$VER" /usr/src/linux >/dev/null 2>&1
	echo 'done.'
}

kernel_module_deb_installer()
{
	local moduleList='acer_acpi acerhk acx atl2 aufs av5100 btrfs drbd8 eeepc_acpi em8300 et131x fsam7400 gspca kqemu lirc_modules lirc loop_aes lzma ndiswrapper nilfs omnibook qc_usb quickcam r5u870 r6040 rfswitch rt73 sfc speakup sqlzma squashfs tp_smapi vboxadd vboxdrv'
	local module='' modulePath='' modulePackage='' modulePackageDeb=''
	local installedPackages=''
	
	# try to install external dfsg-free module packages
	for module in $moduleList
	do
		modulePath="$( /sbin/modinfo -k $(uname -r) -F filename "$module" 2>/dev/null )"
		if [ -n "$modulePath" ]; then
			modulePackage="$( dpkg -S $modulePath 2>/dev/null )"
			# need to avoid modules already in the kernel image
			if [ -n "$modulePackage" -a -z "$( grep 'linux-image-' <<< $modulePackage )" ]; then
				modulePackage="$( echo $modulePackage | sed s/$( uname -r ).*/$VER/g )"
				#if grep-aptavail -PX "${modulePackage}" >/dev/null 2>&1; then
				modulePackageDeb=$( ls $modulePackage*.deb 2> /dev/null )
				if [ -n "$modulePackageDeb" -a -f "$modulePackageDeb" ]
				then
					echo $LINE
					echo 'Installing archived kernel module deb: '$modulePackageDeb
					dpkg -i $modulePackageDeb
					installedPackages="$installedPackages $modulePackageDeb"
					if [ "$?" -ne 0 ]; then
						#apt-get --fix-broken install
						:
					else
						# ignore error cases for now, apt will do the "right" thing to get
						# into a consistent state and worst that could happen is some external
						# module not getting installed
						:
					fi
				fi
			fi
		fi
	done
	# get these into system for aptitude
	if [ "$APT_TYPE" == 'aptitude' -a -n "$installedPackages" ];then
		echo "Installing kernel modules with $APT_TYPE to enter them into the $APT_TYPE database now..."
		$APT_TYPE install $installedPackages
	fi
}

madwifi_module_handler()
{
	# hints for madwifi
	if [ -n "$( which m-a >/dev/null )" ];then
		if /sbin/modinfo -k $( uname -r ) -F filename ath_pci >/dev/null 2>&1; then
			if [ -f /usr/src/madwifi.tar.bz2 ]; then
				# user setup madwifi with module-assistant already
				# we may as well do that for him again now
				if [ -d /usr/src/modules/madwifi/ ]; then
					rm -rf /usr/src/modules/madwifi/
				fi
				m-a --text-mode --non-inter -l "$VER" a-i madwifi
			else
				echo $LINE
				echo "Atheros Wireless Network Adaptor will not work until"
				echo "the non-free madwifi driver is reinstalled."
				echo
			fi
		fi
	fi
}

print_complete_message()
{
	# grub notice
	echo $LINE
	echo "Now you can simply reboot when using GRUB (default). If you use the LILO"
	echo "bootloader you will have to configure it to use the new kernel."
	echo
	echo "Make sure that /etc/fstab and /boot/grub/menu.lst use UUID or LABEL"
	echo "based mounting, which is required for classic IDE vs. lib(p)ata changes!"
	echo
	echo "For more details about UUID or LABEL fstab usage see the sidux manual:"
	echo "   http://manual.sidux.com/en/part-cfdisk-en.htm#disknames"
	echo
	echo "Have fun!"
	echo 
}

########################################################################
####  EXECUTE
########################################################################

start_up_tests
set_script_data
set_kernel_img_conf
check_script_dependencies
set_resume_partition # must run after dependency installs
install_kernel_debs
post_kernel_install_steps
kernel_module_deb_installer
madwifi_module_handler
print_complete_message

exit 0
###**EOF**###