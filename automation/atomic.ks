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

firefox_bin="$(command -v firefox || true)"
[[ -n "$firefox_bin" ]] || {
  printf 'Firefox is missing from the Silverblue guest image.\n' >&2
  exit 1
}
desktop_entry=/var/lib/snapd/desktop/applications/firefox_firefox.desktop
install -d -m 0755 "$(dirname "$desktop_entry")"
if [[ ! -e "$desktop_entry" ]]; then
  cat > "$desktop_entry" <<EOF
[Desktop Entry]
Name=Firefox
Comment=Web Browser
Exec=${firefox_bin} %u
Terminal=false
Type=Application
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;
Categories=Network;WebBrowser;
StartupNotify=true
EOF
fi
if [[ -w /usr/share/applications ]]; then
  install -m 0644 "$desktop_entry" /usr/share/applications/firefox_firefox.desktop
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
  fi
fi
install -d -o tester -g tester /home/tester/.config
cat > /home/tester/.config/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=firefox_firefox.desktop
x-scheme-handler/https=firefox_firefox.desktop
text/html=firefox_firefox.desktop
EOF
chown tester:tester /home/tester/.config/mimeapps.list
systemctl set-default graphical.target
touch /var/lib/omnideck-lab-ready
%end
