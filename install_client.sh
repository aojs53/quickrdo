#!/bin/sh

yum -y install http://repos.fedorapeople.org/repos/openstack/openstack-havana/rdo-release-havana-9.noarch.rpm
yum -y install python-novaclient \
    python-neutronclient \
    python-glanceclient \
    python-cinderclient \
    python-swiftclient \
    python-keystoneclient
