#!/bin/sh -e

export LANG=en_US.utf8

function prep {
    setenforce 0
    sed -i.bak 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    yum install -y iptables-services patch
    systemctl stop firewalld.service
    systemctl mask firewalld.service
    systemctl start iptables.service
    systemctl enable iptables.service
}

function rdo_install {
    # https://bugzilla.redhat.com/show_bug.cgi?id=1014311
    yum -y install mariadb-server
    rm -f /usr/lib/systemd/system/mariadb.service
    cp /usr/lib/systemd/system/mysqld.service /usr/lib/systemd/system/mariadb.service

    yum -y install http://repos.fedorapeople.org/repos/openstack/openstack-havana/rdo-release-havana-9.noarch.rpm
    yum -y install openstack-packstack

    ./lib/genanswer.sh controller
    packstack --answer-file=controller.txt

    # https://bugzilla.redhat.com/show_bug.cgi?id=1103800
    list=("/usr/lib/python2.7/site-packages/cinder/openstack/common/rpc/impl_qpid.py" \
          "/usr/lib/python2.7/site-packages/keystone/openstack/common/rpc/impl_qpid.py" \
          "/usr/lib/python2.7/site-packages/neutron/openstack/common/rpc/impl_qpid.py" \
          "/usr/lib/python2.7/site-packages/nova/openstack/common/rpc/impl_qpid.py")
    for module in ${list[@]}; do
        sed -i 's/\(^            node_name = \)msg_id$/\1"%s\/%s" % (msg_id, msg_id)/' $module
    done

    # https://bugzilla.redhat.com/show_bug.cgi?id=1139907
    patch -p0 -Nsb /usr/lib/python2.7/site-packages/cinder/backup/api.py < lib/cinder_backup_api.py.patch

    if virsh net-info default | grep -q -E "Active: *yes"; then
        virsh net-destroy default
        virsh net-autostart default --disable
    fi

    systemctl stop openstack-nova-compute.service 
    systemctl disable openstack-nova-compute.service 
    systemctl stop openstack-cinder-volume.service
    systemctl disable openstack-cinder-volume.service
    systemctl stop openstack-cinder-backup.service
    systemctl disable openstack-cinder-backup.service

    openstack-config --set /etc/nova/nova.conf DEFAULT cinder_cross_az_attach False
    openstack-config --set /etc/cinder/cinder.conf DEFAULT default_availability_zone az1
    openstack-config --set --existing /etc/swift/proxy-server.conf filter:keystone operator_roles 'admin, SwiftOperator, _member_'
    openstack-config --set /etc/nova/nova.conf DEFAULT default_availability_zone az1
    openstack-config --set /etc/nova/nova.conf DEFAULT allow_resize_to_same_host true

    cat <<'EOF' >/etc/rc.d/rc.local
#!/bin/sh
for i in $(ip -o link | awk -F: '/ eth[0-9]+/{print $2}'); do
  ethtool -K $i tx off gro off gso off
done
(sleep 10 && systemctl restart qpidd.service) &
EOF
    chmod u+x /etc/rc.d/rc.local

    cat <<'EOF' >/usr/local/bin/disable_qr_offload.sh
#!/bin/sh
PATH=$PATH:/usr/sbin
for n in $(ip netns | grep -E "^qrouter-"); do
  for i in $(ip netns exec $n ip -o link | awk -F: '/ qr-/{print $2}'); do
    ip netns exec $n ethtool -K $i tx off gro off gso off
  done
done
EOF
    chmod u+x /usr/local/bin/disable_qr_offload.sh

    crontab -l > /tmp/cron_tmp$$ || :
    cat <<'EOF' >> /tmp/cron_tmp$$
* * * * * /usr/local/bin/disable_qr_offload.sh >/dev/null 2>&1
EOF
    crontab /tmp/cron_tmp$$
    rm -f /tmp/cron_tmp$$
}

# main

echo
echo "Doing preparations..."
echo
prep 2>/dev/null

echo
echo "Installing RDO with packstack...."
echo
rdo_install 2>/dev/null

echo
echo "Done. Now, you need to reboot the server."

