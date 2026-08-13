# Fedora Silverblue 44 unattended install for the disposable OmniDeck VM lab.
# This guest has exactly one writable disk: /dev/vda.

text
lang en_US.UTF-8
keyboard --xlayouts='us'
timezone America/Chicago --utc

network --bootproto=dhcp --device=link --activate --onboot=yes --hostname=omnideck-atomic

rootpw --lock
user --name=tester --groups=wheel --password=$6$wBK.1ptv0u8Mxakv$XdYXpNovpLu9lmFM4wy9HnD0ig35VvC0hjqQ0hW5aw8ENrODoCamhjR91Ee37hJqg57Yok1rRdO0POZx6edEu. --iscrypted --gecos="OmniDeck tester"
sshkey --username=tester "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBtgEDHDtGv8c9hkTV4D2U1RuLha5n1YvfqxlTd5tAqv omnideck-release-lab"

firstboot --disable
firewall --enabled --service=ssh
selinux --enforcing
services --enabled=sshd
eula --agreed

ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=btrfs
bootloader --append="console=tty0 console=ttyS0,115200n8"

ostreesetup --nogpg --osname=fedora --remote=fedora --url=file:///ostree/repo --ref=fedora/44/x86_64/silverblue

poweroff

%post --erroronfail
install -d -m 0750 /etc/sudoers.d
printf 'tester ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-omnideck-lab
chmod 0440 /etc/sudoers.d/90-omnideck-lab
systemctl set-default graphical.target
touch /var/lib/omnideck-lab-ready
%end
