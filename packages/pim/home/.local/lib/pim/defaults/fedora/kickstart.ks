# pim's default Fedora kickstart. Its variables come from pim (`pim help`): an image overrides them with
# vars: in image.yml, or replaces this file with its own kickstart.ks.
text
skipx
firstboot --disable
# pim waits for the installer VM to power off
poweroff

# netinst ISOs carry no packages: install from the mirrors
url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"

lang ${LOCALE}
keyboard --xlayouts=${KEYBOARD}
timezone ${TIMEZONE}
network --bootproto=dhcp --device=link --activate --hostname=${HOSTNAME}

zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --type=plain --noswap
bootloader --timeout=1

# The user logs in with the image's key; the password is locked unless user.password_hash is set
rootpw --lock
user --name=${USER} --gecos="${FULLNAME}" --groups=wheel ${KS_PASSWORD}
sshkey --username=${USER} "${SSH_PUBKEY}"

selinux --enforcing
firewall --enabled --service=ssh
services --enabled=sshd,qemu-guest-agent

%packages
@core
openssh-server
curl
sudo
qemu-guest-agent
%end

%post --log=/root/ks-post.log
echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER}
chmod 440 /etc/sudoers.d/${USER}
%end
