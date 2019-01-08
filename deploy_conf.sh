#!/bin/bash

# Email notifications
CDM_MAIL='admin@mail'

# Service files
LOGFILE=${SCRIPT_PATH}/log/${DESCR}.log
LOGF_QUIET=${SCRIPT_PATH}/log/${DESCR}_quiet.log
#LOGF_FULL=${SCRIPT_PATH}/log/deploy_full.log
PIDFILE=${SCRIPT_PATH}/pidfile

# timeouts
timeout_deploy_cp='30m'
timeout_build_node='60m'
timeout_deploy_node='20m'
#timeout_deploy_node='7s'
timeout_test_cp='20m'
timeout_test_node='20m'

# min free space on servers storages in Gb 
FS_ALERT=5 
FS_ALERT_builder=5
FS_ALERT_node=6
FS_ALERT_dev=5
FS_ALERT_stage=5
FS_ALERT_prod=5

# calculate branch version
[[ -z "${b}" ]] && b='trunk'
bv=${b/tags\/}

# RPM build data
prrev=${bv}
prver=`date +%Y%m%d_%H%M00`
pruser=dome
prworkdir=/opt/${pruser}
# basearch=$(rpm -q --qf "%{arch}" -f /etc/$(sed -n 's/^distroverpkg=//p' /etc/yum.conf))
BUILD_DIR=${HOME}/RPM_BUILD/${bv}/${t}
RPM_DIR_BASEARCH=${BUILD_DIR}/RPMS/x86_64
RPM_DIR_NOARCH=${BUILD_DIR}/RPMS/noarch # noarch should be deprecated

# SVN data
svn_user=
svn_passwd=

# ${b}, ${t}, ${s} are taken from script arguments
svn_url_all=serverurl/cdm
svn_url_cp=${svn_url_all}/portal/${b}
svn_url_node=${svn_url_all}/node/${b}
svn_url_ci=${svn_url_all}/ci/${b}

svn_url_yumrepo=${svn_url_ci}/yum.repo
eval svn_url=\${svn_url_${t}}

svn_url_specs_cp=${svn_url_cp}/image/repo/7/SPECS
svn_url_specs_node=${svn_url_node}/image/repo/7/SPECS
svn_url_specs=${svn_url}/image/repo/7/SPECS
svn_dir_specs=${SCRIPT_PATH}/SPECS/${b}/${t}
#specs_excluded='init' # for building all specs
#specs_excluded='squid[0-9]+|cavld|pdnsd' # for `egrep -iv ${specs_excluded}`
specs_excluded='squid[0-9]' # for `egrep -iv ${specs_excluded}`
#specs_excluded='dome|pdns|cavl' # for `egrep -iv ${specs_excluded}`

svn_url_sources=${svn_url}/image/repo/7/SOURCES
svn_dir_sources=${BUILD_DIR}/SOURCES

eval svn_url_packages=\${svn_url_${t}}/image/packages
svn_dir_packages=${RPM_DIR_BASEARCH}

svn_url_docker_cp=https://url/svn/cdm/docker/${b}/build/portal
svn_url_docker_node=https://url/svn/cdm/docker/${b}/build/node
eval svn_url_docker=\${svn_url_docker_${t}}
svn_dir_docker=${SCRIPT_PATH}/Dockerfiles/${b}/${t}

# docker build
[[ -z ${N} ]] && { echo -e "CONF script: NO LABEL ('N')! Exporting current label ($m $t $s)\n"; export N=`date +%Y%m%d_%H%M00`; }
D_IMAGE=dome_${t}:${N}
#IMAGE_TAR=dme_${t}_${N}_${bv}.tar
IMAGE_TAR=dme_${t}_${N}.tar
IMAGE_LATEST=dme_${t}_latest.tar.gz
FDESCR_LATEST=dme_latest.descr

###--- Repositories paths ---###

# images repos FS and NET - absolute names (Uppercase)
FS_IMG_PATH_BUILD=/storage/dme
FS_IMG_PATH_CP=/opt/dme/public_portal/images
NET_BSERVER=http://buildserverIP
NET_IMG_SRV_BUILD=${NET_BSERVER}/dme
NET_IMG_SRV_CP_stage=https://stage/images
NET_IMG_SRV_CP_prod=https://prod/images
eval NET_IMG_SRV_CP=\${NET_IMG_SRV_CP_${s}}


# images repos RPM, FS and NET - relative names (Lowercase)

# rpm repo
# the same as for images for usability

REPO_DIR=/storage/dme/${bv}/${t}
REPO_DIR_BASEARCH=${REPO_DIR}/x86_64
NET_REPO=${NET_BSERVER}/dme/${bv}/${t}
url_basearch=${NET_REPO}/'$basearch'

fs_img_tar_build="${FS_IMG_PATH_BUILD}/${IMAGE_TAR}"
fs_img_gz_build="${fs_img_tar_build}.gz"
fs_img_latest_build="${FS_IMG_PATH_BUILD}/${IMAGE_LATEST}"

fs_img_tar_cp="${FS_IMG_PATH_CP}/${IMAGE_TAR}"
fs_img_gz_cp="${fs_img_tar_cp}.gz"
fs_img_latest_cp="${FS_IMG_PATH_CP}/${IMAGE_LATEST}"
fs_img_latest_md5="${fs_img_latest_cp}.md5"

net_img_build="${NET_IMG_SRV_BUILD}/${IMAGE_TAR}.gz"
net_img_latest_build="${NET_IMG_SRV_BUILD}/${IMAGE_LATEST}"

net_img_cp="${NET_IMG_SRV_CP}/${IMAGE_TAR}.gz"
net_img_latest_cp="${NET_IMG_SRV_CP}/${IMAGE_LATEST}"
net_img_latest_md5="${net_img_latest_cp}.md5"

###---   END Repo paths   ---###

# ssh data
ssh_key_dev='/root/dev.pem'
ssh_key_stage='/root/stage.pem'
ssh_key_prod='/root/production.pem'
eval ssh_key=\${ssh_key_${s}}
ssh_user_dev='root'
ssh_user_stage='centos'
ssh_user_prod='centos'
eval ssh_user=\${ssh_user_${s}}
ssh_host_dev='devserver'
ssh_host_stage='stageserver'
ssh_host_prod='prodserver'
eval ssh_host=\${ssh_host_${s}}

# Dev instances data
TEST_CP_IP='1111'
TEST_NODE_IP='12121'
#old: DEV_NODES_POOL=(1111 2222 3333 4444)
DEV_NODES_POOL=(1111)
node_path='/var/lib/docker'
node_image_tar="${node_path}/${IMAGE_TAR}"
node_image_gz="${node_image_tar}.gz"

### Commands part ###

r_cp_gunzip="if [[ ! -e ${IMAGE_TAR} ]];then gunzip ${IMAGE_TAR}; fi"
r_cp_docker_load="docker load < ${IMAGE_TAR}"
r_cp_docker_create_dev="docker create --restart=always -p 222:22 -p 1000:1000 -p 1001:1001 --add-host pg.host:111111 --add-host memcache.host:222222 --add-host accouns:333333 --add-host logs:44444 -v /opt/dme/public_cp:/opt/dme/public_portal --name cp_${N} ${D_IMAGE}"
  r_cp_docker_create_stage="docker create --restart=always -p 222:22 -p 10080:10080 -p 10050:10050 --add-host pg.cp.dome:172.17.42.1 --add-host memcache.cp.dome:172.17.42.1 --add-host mssp-dev-node1:209.126.110.244 --add-host domedev.mssp-dev-node1:209.126.110.244  -v /opt/dome/public_cp:/opt/dome/public_cp --name cp_${N} ${D_IMAGE}"
  r_cp_docker_create_prod="docker create --restart=always -p 1000:1000 -p 1001:1001 --add-host pg.host:111 --add-host memcache.host:222 -v /opt/dme/data/idata:/opt/dme/data/idata -v /opt/dme/public_cp:/opt/dme/public_portal --name cp_${N} ${D_IMAGE}"
eval r_cp_docker_create=\${r_cp_docker_create_${s}}

r_cp_docker_copy_yml_dev="docker cp /root/config.yml cp_${N}:/opt/dme/web/config/"
r_cp_docker_copy_yml_stage="docker cp /home/centos/config.yml cp_${N}:/opt/dme/web/config/"
eval r_cp_docker_copy_yml=\${r_cp_docker_copy_yml_${s}}

r_node_move="mv ${IMAGE_TAR}.gz ${FS_IMG_PATH_CP}"
#old: r_node_prepare_image="cd ${CP_IMAGE_PATH} && ln -sf ${IMAGE_TAR}.gz latest.tar.gz && md5sum latest.tar.gz > comodo_dome_qlatest.tar.gz.md5"
#old2: r_node_prepare_image="cd ${FS_IMG_PATH_CP} && ln -sf ${IMAGE_TAR}.gz ${IMAGE_LATEST} && md5sum ${IMAGE_LATEST} > ${IMAGE_LATEST}.md5"
r_node_prepare_image="cd ${FS_IMG_PATH_CP} && ln -sf ${IMAGE_TAR}.gz ${IMAGE_LATEST} && md5sum ${IMAGE_LATEST} > ${IMAGE_LATEST}.md5 && echo ${N} > ${FDESCR_LATEST} && echo ${IMAGE_TAR} >> ${FDESCR_LATEST}"
#r_node_prepare_image="cd ${FS_IMG_PATH_CP} && echo ${N} > ${FDESCR_LATEST} && echo ${IMAGE_TAR} >> ${FDESCR_LATEST}"

# compile remote commands
declare -a remote_command_cp=( "${r_cp_gunzip}" "${r_cp_docker_load}" "${r_cp_docker_create}" "${r_cp_docker_copy_yml}" )
declare -a remote_command_node=( "${r_node_move}" "${r_node_prepare_image}" )

# Main evaluation of remote command
eval remote_command=( \"\${remote_command_${t}[@]}\" )
#eval remote_command=( \"\${remote_command_${s}_${t}[@]}\" )

### END of Commands part ###
