#!/bin/bash

# get main path
pushd `dirname $0` > /dev/null
SCRIPT_PATH=`pwd`
popd > /dev/null

#source ${SCRIPT_PATH}/deploy_conf.sh

# check logfile
function check_logfiles() {
  for LOGF in ${LOGFILE} ${LOGF_QUIET}; do
    if [[ ! -f "${LOGF}" ]]; then
      [[ ! -d `dirname ${LOGF}` ]] && mkdir -p `dirname ${LOGF}`
      touch ${LOGF} || echo "WARNING! Can not create log file ${LOGF}!"
    fi
  done
  # create file descriptor for full output
  #exec 3> >(tee ${LOGF_FULL})
  return 0
}

# reset log files
# save old logfiles and clear current
function logs_reset() {
  # do save, clear and cleanup
  for LOGF in ${LOGFILE} ${LOGF_QUIET}; do
    cp ${LOGF} ${LOGF}_before_${N}
    echo "" | tee ${LOGF}
    find $(dirname ${LOGF}) -maxdepth 1 -type f -path "${LOGF}_*" | sort -r | awk 'NR>3' | xargs rm -f
  done
}

# log a string
# -q - not show, just log to file
function do_log() {
  if [ x"$1" == x"0" ]; then
    shift
    echo -ne "`date +'%d-%m-%Y %H:%M:%S'` [${DESCR}] $*\n" | tee -a ${LOGFILE} ${LOGF_QUIET}
  else 
    echo -ne "`date +'%d-%m-%Y %H:%M:%S'` [${DESCR}] $*\n" | tee -a ${LOGFILE}
  fi
  #echo >&2 "| LOG : $*"
}

# log stdin
#log2() {
#  while read LINE; do
#    log $* "$LINE"
#  done
#}

function do_exit_ok() {
  local msg=$1
  [[ -n $2 ]] && local rcode=$2 || local rcode=0
  do_log 0 "${msg}. EXIT"
#  3>&-
#  cat ${LOGF_FULL} >> ${LOGFILE}
  exit $rcode
}

function do_exit_error() {
  local msg=$1
  [[ -n $2 ]] && local rcode=$2 || local rcode=1
  do_log 0 "ERROR EXIT! ${msg}. ERROR EXIT!"
#  3>&-
  exit $rcode
}

# check and create pid file
# needs pid as argument
function create_pid() {
  [[ -f ${PIDFILE} ]] && oldpid=$(cat ${PIDFILE}) || oldpid='no_such_pid'
  echo "-- Oldpid: $oldpid"
  if sudo kill -0 ${oldpid} 2>/dev/null; then
    echo "Another process is started (${oldpid})"
    exit 1
  else
    echo $1 > ${PIDFILE} || do_exit_error "Can not save pidfile ${PIDFILE}"
    do_log "Pidfile created: ${PIDFILE} (${1})"
  fi
}

# convert seconds to day-hour-min-sec
function convert_dhms() {
  ((d=${1}/(60*60*24)))
  ((h=(${1}%(60*60*24))/(60*60)))
  ((m=(${1}%(60*60))/60))
  ((s=${1}%60))
  echo $(printf "%02d days %02d hours %02d minutes %02d seconds" $d $h $m $s)
}

# returns how long ago last rpm build occured
# based on repodata dir timestamp
function get_last_repo_mod() {
  [[ ! -d ${RPM_DIR_BASEARCH}/repodata ]] && { echo "no timestamp"; return 0;  }
  local mod=$(stat -c %Y ${RPM_DIR_BASEARCH}/repodata)
  local now=$(date +"%s")
  local elapsed=$((${now}-${mod}))
  echo $(convert_dhms $elapsed)
}

## Yes/No prompt function (message as agrument $1)
function continue_yn() {
  while true; do
    read -p "$1" yn
    case $yn in
      [Yy]* ) break;;
      [Nn]* ) do_exit_ok 'Finished by users prompt';;
      * ) echo 'Please answer yes or no';;
    esac
  done
}

# timeout status processing
function timeout_status() {
  code=$1
  [[ $code == 124 ]] && { do_log "WARNING! Failed operation by timeout; code ($code)"; return 1; }
  [[ $code != 0 ]] && { do_log "WARNING! Failed operation; code ($code)"; return 1; }
  [[ $code == 0 ]] && { do_log "Got status OK; code ($code)"; return 0; }
  do_log 0 "Error with status code ($code) parsing!"
  return 1
}

## make cleanup of files by mask
function cleanup_by_mask() {
  [[ -n $1 ]] && local targetdir=$1 || { do_log "ERROR with cleanup options, skipping"; return 1; }
  [[ -n $2 ]] && local mask=$2 || { do_log "ERROR with cleanup options, skipping"; return 1; }
  [[ -n $3 ]] && local keep=$3 || { do_log "ERROR with cleanup options, skipping"; return 1; }
  [[ ! -d ${targetdir} ]] && { do_log "Warning! Cleanup directory not found (${targetdir}), skipping"; return 0; }
  do_log "Starting cleanup of '${targetdir}'; mask '${mask}'; keep '${keep}'"
  old_found=$(find ${targetdir} -maxdepth 1 -type f -path "${mask}"| sort -rV | awk "NR>${keep}")
  if [[ -n ${old_found} ]]; then
    do_log "Found old files: ${old_found}"
  else 
    do_log "Nothing found"; return 1;
  fi
  echo ${old_found} | xargs rm -f || { do_log "ERROR while cleanup files by mask '${mask}'"; return 1; }
  return 0
}

## main function which builds RPM packeages after cleanup (leaves 2 latest of each package)
# arguments are 
#  - path to spec file
#  - option for rpmbuild (-bb)
function rpmb() {
  ## Set rpmbuild parameters variables (just simplified from old crpmbuild script)
  # check version number
  [[ "$prver=" == '=' ]] && prver=1.0
  # check revision number
  [[ "$prrev=" == '=' ]] && prrev=`date +%Y%m%d_%H%M%S`
  # check user
  [[ "$pruser=" == '=' ]] && pruser=fakeuser
  # check workdir
  [[ "$prworkdir=" == '=' ]] && prworkdir=fakedir
  # check svn repo dir
  [[ x"$svn_repo=" == 'x' ]] && do_exit_error 'No svn repo provided to rpm builder'
  do_log "Options for rpmbuild: prver=$prver; prrev=$prrev; pruser=$pruser; prworkdir=$prworkdir"

  # Deleting old packages except last 2
  # get searchable name from full path to spec (/home/builder/deploy/SPECS/trunk/cp/dome-mssp-reports.spec)
  # get the basename and then cut last 5 symbols (.spec) to get searchable name: dome-mssp-reports and save to local variable
  ## also works: local search_name=$(basename ${2::-5})
  local search_name=$(basename ${2} .spec)
  do_log "Find old packages for search name: ${search_name}"

  cleanup_by_mask ${RPM_DIR_BASEARCH} "*${search_name}*.rpm" 0
### - soon may be deleted as deprecated
###  local old_found=$(find ${RPM_DIR_BASEARCH} -maxdepth 1 -type f -path "*${search_name}*.rpm"| sort -r | awk 'NR>1')
###  do_log "Found old packages: ${old_found}"
###  echo ${old_found} | xargs rm -f

  do_log 'Cleanup finisned, starting rpmbuild'
  # Now rpmbuild
  rpmbuild --quiet -D "prver $prver" -D "prrev $prrev" -D "pruser $pruser" -D "prworkdir $prworkdir" \
           -D "svn_user $svn_user" -D "svn_passwd $svn_passwd" -D "svn_repo $svn_url" $@

#  do_log "Build complete, saving sha1 sum"
  #rpm_file="${RPM_DIR_BASEARCH}/${search_name}-${prver}-${prrev}.x86_64.rpm"
#  rpm_file=$(ls ${RPM_DIR_BASEARCH}/*${search_name}*${prrev}*.rpm)
#  [[ -z ${rpm_file} ]] && { do_log "Have not found rpm based on name ${search_name}, skipping sha1sum calculation"; return; }
#  do_log "Found file ${rpm_file}, calculating sum"
  # sha1sum=$(whereis sha1sum | awk '{print $2}'); $sha1sum <target file>
#  /usr/bin/sha1sum ${rpm_file} > ${rpm_file}.sha1
}

###################################
#### Free space check section #####

## Get free space info from servers
function get_free_space() {
  case "$1" in
  "builder")
     echo $(df -k 2>/dev/null | grep centos-root | awk '{print $4 " " $6}') 
  ;;
  "dev") # means cp instance
     echo $(sudo ssh -i /root/cdome-cp-dev.pem root@devserver "sudo df -k | grep centos-root" | awk '{print $4 " " $6}')
  ;;
  "stage") # means cp instance
     echo $(sudo ssh -i /root/dome-cp-stage.pem centos@stageserver "sudo df -k | grep xvda1" | awk '{print $4 " " $6}')
  ;;
  "prod") # means cp instance
     echo $(sudo ssh -i /root/cdome-cp-production.pem centos@prodserver "sudo df -k | grep xvda1" | awk '{print $4 " " $6}')
  ;;
  "node")
     echo $(df -k | grep docker | awk '{print $4 " " $6}') 
  ;;
  *   )  echo "0";
  esac
}

## Get free space specific details info from servers
function get_free_space_partition() {
  [[ -n $1 ]] && local host=$1 || { do_log "No target id specified"; return 1; }
  string=$(get_free_space ${host})
  if [[ -z ${string} || "x$string" == 'x0' ]]; then
    do_log "Warning! Can not get info about free space on server ${host}"
    break
  fi
  partition=$(echo $string | awk '{print $2}')
  echo "$partition"    
}
## Get free space specific details info from servers
function get_free_space_size() {
  [[ -n $1 ]] && local host=$1 || { do_log "No target id specified"; return 1; }
  string=$(get_free_space ${host})
  if [[ -z ${string} || "x$string" == 'x0' ]]; then
    do_log "Warning! Can not get info about free space on server ${host}"
    break
  fi
  free=$(echo $string | awk '{ print $1}')
  free=$(echo "scale=1; ${free}/1024/1024" | bc)
  echo "$free"    
}

## Make Cleanups
function make_cleanup() {
  case "$1" in
  "builder")
    ## Docker repo cleaning
    do_log '-- Starting cleanup of non-important docker containers and images'
    local containers=$(docker ps -a | egrep -v 'CONT' | awk '{ print $1; }')
    [[ ! -z ${containers} ]] && echo ${containers} | xargs -L1 docker rm -f
    do_log "Found non-important docker containers: ${containers}"
    local images=$(docker images | egrep -v 'IMAGE|latest|centos' | awk '{ print $3; }')
    [[ ! -z ${images} ]] && echo ${images} | xargs -L1 docker rmi -f
    do_log "Found non-important docker images: ${images}"
    do_log '-- Cleanup of Docker repo finished'
    ## Docker archives cleaning
    cleanup_by_mask ${FS_IMG_PATH_BUILD} "*dome_cp*.tar*" 2
    cleanup_by_mask ${FS_IMG_PATH_BUILD} "*dome_node*.tar*" 2
    do_log "-- Cleanup of (${FS_IMG_PATH_BUILD}) directory finished"
    ## rpms cleaning
    cleanup_by_mask ${RPM_DIR_BASEARCH} "*dome-interceptor*.rpm" 2
    cleanup_by_mask ${RPM_DIR_BASEARCH} "*dome-locations*.rpm" 2
    cleanup_by_mask ${RPM_DIR_BASEARCH} "*dome-interceptor*.sha1" 2
    cleanup_by_mask ${RPM_DIR_BASEARCH} "*dome-locations*.sha1" 2
    do_log "-- Cleanup of (${RPM_DIR_BASEARCH}) directory finished"
    do_log "-- Cleanup of $1 finished"
  ;;
  "dev")
     sudo ssh -i /root/cdome-cp-dev.pem root@devserver "/root/deploy/cleanup/cleanup_cp_dev.sh"
  ;;
  "stage")
     sudo ssh -i /root/dome-cp-stage.pem centos@stageserver "sudo ~/cleanup_cp_stage.sh"
  ;;
  "prod")
     sudo ssh -i /root/cdome-cp-production.pem centos@prodserver "sudo ~/cleanup_cp_prod.sh"
  ;;
  "node")
     /root/deploy/cleanup/cleanup_node.sh
  ;;
  *   )  echo "0";
  esac
}

## Free space analyser and cleaner
function check_space_and_cleanup() {
  [[ -n $1 ]] && local host=$1 || { do_log "No cleanup target id specified"; return 1; }
  # try to get spesific space limit or use the default one
  eval FS_ALERT_HOST=\${FS_ALERT_${host}}
  [[ -n ${FS_ALERT_HOST} ]] && FS_ALERT=${FS_ALERT_HOST} 
  do_log "-- Checking free space on host id ${host} (min amount: ${FS_ALERT}G)"
  # 1st run - check and cleanup, 2nd run - check and return error if not passed
  for i in 1 2; do
    partition=$(get_free_space_partition ${host})
    free=$(get_free_space_size ${host})
    if [[ $(echo "${free} < ${FS_ALERT}" | bc) -eq 1 ]]; then
      do_log "Running out of space: partition $partition has ${free}G of free space on server ${host}"
      if [[ x"$i" == x'1' ]]; then
        do_log "Make cleanup for server ${host}"
        make_cleanup $host
      else
        #?some shit [[ ${host} == 'builder' ]] && { do_log "Running out of space can not be fixed: partition $partition has ${free}G of free space on server ${host}"; return 1; }
        do_log "Running out of space can not be fixed: partition $partition has ${free}G of free space on server ${host}"
        return 1
      fi
    else
       do_log "Free space OK for server ${host} (${free}G)"
       return 0
    fi
  done
  do_log "Something went wrong with check_space_and_cleanup function"
  return 1
}

####################################
######## SVN check section #########

## function does:
#  - checking if there is svn repo dir
#  - creation of svn repo dir if not 
#  - svn up to svn repo dir
function svn_check() {
  local svn_url=$1
  local svn_dir=$2
  # check that svn directory exists
  if [[ ! -d ${svn_dir} ]]; then
    do_log "No svn directory found. Trying to create ${svn_dir}"
    mkdir -p ${svn_dir} || do_exit_error "Can not create svn directory (${svn_dir})"
  fi
  # check that svn directory is versioned and update or checkout
  if svn info ${svn_dir} > /dev/null 2>&1; then
    do_log "Svn directory (${svn_dir}) connected to svn. Updating"
    svn revert -R --username=${svn_user} --password=${svn_passwd} --no-auth-cache ${svn_dir} || do_exit_error "Failed svn revert directory ${svn_dir}"
    svn up --username=${svn_user} --password=${svn_passwd} --no-auth-cache ${svn_dir} || do_exit_error "Failed svn up directory ${svn_dir}"
  else 
    #do_log "Svn directory (${svn_dir}) exists but not connected. It should be purged and re-checked out"
    #[[ ${svn_dir} == '/' ]] && do_exit_error "Can purge svn directory (${svn_dir}), it's system dir"
    #rm -rf ${svn_dir}/*
    #mkdir -p ${svn_dir} || do_exit_error "Can not create svn directory (${svn_dir})"
    if svn ls ${svn_url} > /dev/null 2>&1; then
      do_log "Try to svn checkout to ${svn_dir}"
      svn co --username=${svn_user} --password=${svn_passwd} --no-auth-cache ${svn_url}/ ${svn_dir}/ || do_exit_error "Failed checkout svn directory ${svn_url}"
    else
      do_log "Warning! Svn url (${svn_url}) is unavailable!"
    fi
  fi
}
## Check svn SPEC files
function check_svn_specs() {
  do_log '-- Checking svn specs'
  svn_check ${svn_url_specs}/ ${svn_dir_specs}/
}

## Check svn SPEC files for Node and CP (both)
function check_svn_specs_all() {
  do_log '-- Checking svn specs for all dome parts'
  svn_check ${svn_url_specs_node}/ ${svn_dir_specs}/
  svn_check ${svn_url_specs_cp}/ ${svn_dir_specs}/
}

## Check Dockerfile spec
function check_svn_dockerfiles() {
  do_log '-- Checking svn dockerfiles'
  svn_check ${svn_url_docker}/ ${svn_dir_docker}/
  # modify Dockerfile
  sed -i "/ENV CW_REPO_URL/s/$/\/${bv}\/${t}/" "${svn_dir_docker}/Dockerfile"
}

## Check Sources
function check_svn_sources() {
  do_log '-- Checking svn sources'
  svn_check ${svn_url_sources}/ ${svn_dir_sources}/
}

## Check Packages
function check_svn_packages() {
  do_log '-- Checking svn packages'
  svn_check ${svn_url_packages}/ ${svn_dir_packages}/
}

## Check RPM Repo
function check_rpm_repo() {
  do_log '-- Checking RPM repo structure'
  svn_check ${svn_url_yumrepo}/ ${REPO_DIR}/
  do_log '-- Change repo template'
  sed -i "s|%url_basearch%|${url_basearch}|g" ${REPO_DIR}/*.repo || { do_log 0 "CRITICAL! Can not prepare repo file!"; return 1; }
  sed -i "s|%url_noarch%|${url_noarch}|g" ${REPO_DIR}/*.repo || { do_log 0 "CRITICAL! Can not prepare repo file!"; return 1; }
  #sed -i "s|%url_basearch%|${url_basearch}|g" "${REPO_DIR}/our.repo" || { do_log 0 "CRITICAL! Can not prepare repo file!"; return 1; }
  #sed -i "s|%url_noarch%|${url_noarch}|g" "${REPO_DIR}/our.repo" || { do_log 0 "CRITICAL! Can not prepare repo file!"; return 1; }
}

## Check docker service
function check_docker_service() {
  if ! killall -0 dockerd 2>/dev/null && ! killall -0 docker 2>/dev/null; then
    do_log "Docker is not started, trying to start"
    systemctl start docker || { do_log 0 "CRITICAL! Can not start docker service!"; return 1; }
  fi
  return 0
}

#------------ DEPRECATED -----------#



####################################
######### Cleanup Section ##########

## Docker repo cleaning
function cleanup_docker_old() {
  do_log '-- Starting cleanup of non-important docker containers and images'
  local containers=$(docker ps -a | egrep -v 'CONT' | awk '{ print $1; }')
  [[ ! -z ${containers} ]] && echo ${containers} | xargs -L1 docker rm -f
  do_log "Found non-important docker containers: ${containers}"
  local images=$(docker images | egrep -v 'IMAGE|latest|centos' | awk '{ print $3; }')
  [[ ! -z ${images} ]] && echo ${images} | xargs -L1 docker rmi -f
  do_log "Found non-important docker images: ${images}"
  do_log '-- Cleanup of Docker repo finished'
}
## Docker archives cleaning
function cleanup_images_old() {
  do_log "-- Starting cleanup of '${FS_IMG_PATH_BUILD}' for old Docker .tar.* images"
  for mask in "*dome_cp*.tar" "*dome_node*.tar"; do
    old_found=$(find ${FS_IMG_PATH_BUILD} -maxdepth 1 -type f -path "${mask}"| sort -rV | awk 'NR>2')
    [[ -z ${old_found} ]] && { do_log "Nothing found by mask '${mask}'. Continue"; continue; }
    do_log "Found old images in ${FS_IMG_PATH_BUILD} by mask '${mask}': ${old_found}"
    echo ${old_found} | xargs rm -f || do_log "ERROR while cleanup images by mask '${mask}'"
    do_log "Cleanup finisned by mask '${mask}'"
  done
  do_log '-- Cleanup of Docker archived images finished'
}
####################################

## Get free space info from servers
function get_free_space_old() {
  case "$1" in
  "localhost")
     echo $(df -k 2>/dev/null | grep centos-root | awk '{print $4 " " $6}') 
  ;;
  "dev")
     #[[ -z ${m} || ${m} != 'full' ]] && { do_log "Not 'full' deployment mode, skipping ${1} checking"; echo "skip"; break; }
     echo $(sudo ssh -i /root/cdome-cp-dev.pem root@devserver "sudo df -k | grep centos-root" | awk '{print $4 " " $6}')
  ;;
  "stage")
     #[[ -z ${m} || ${m} != 'full' ]] && { do_log "Not 'full' deployment mode, skipping ${1} checking"; echo "skip"; break; }
     echo $(sudo ssh -i /root/dome-cp-stage.pem centos@stageserver "sudo df -k | grep xvda1" | awk '{print $4 " " $6}')
  ;;
  "prod")
     #[[ -z ${m} || ${m} != 'full' ]] && { do_log "Not 'full' deployment mode, skipping ${1} checking"; echo "skip"; break; }
     echo $(sudo ssh -i /root/cdome-cp-production.pem centos@prodserver "sudo df -k | grep xvda1" | awk '{print $4 " " $6}')
  ;;
  "node")
     echo $(df -k | grep centos-root | awk '{print $4 " " $6}') 
  ;;
  *   )  echo "0";
  esac
}

## Free space analyser and cleaner
function check_space_and_cleanup_old() {
  do_log "-- Checking free space on servers (min amount: ${FS_ALERT}G)"
  [[ -z $1 ]] && local mode='exitmode' || local mode=$1
  for host in localhost ${s}; do
    # skip testing localhost (build server) for node instance
    [[ ${s} == 'node' && ${host} == 'localhost' ]] && continue
    do_log "Server ${host}"
    #string=`df -k | grep -vE "^Filesystem|tmpfs|devtmpfs|cdrom|boot|mnt" | awk '{print $4 " " $6}'`
    string=$(get_free_space ${host})
    if [[ -z ${string} || "x$string" == 'x0' ]]; then
      do_log "Warning! Can not get info about free space on server ${host}"
      continue
    fi
    #[[ ${string} == 'skip' ]] && continue
    free=$(echo $string | awk '{ print $1}')
    free=$(echo "scale=1; ${free}/1024/1024" | bc)
    partition=$(echo $string | awk '{print $2}')
    if [[ $(echo "${free} < ${FS_ALERT}" | bc) -eq 1 ]]; then
      do_log "Running out of space: partition $partition has ${free}G of free space on server ${host}"
      if [[ x"$mode" == x'cleanupmode' ]]; then
        do_log "Make cleanup for server ${host}"
        make_cleanup $host
      else
        [[ ${s} != 'node' ]] && do_exit_error "Running out of space: partition $partition has ${free}G of free space on server ${host}"
      fi
    else
       do_log "Free space OK for server ${host} (${free}G)"
    fi
  done
  do_log 'OK (Free space on servers)'
}

# check and create pid file
# needs pid as argument
function create_pid_old() {
  [[ -f ${PIDFILE} ]] && oldpid=$(cat ${PIDFILE}) || oldpid='no_such_pid'
  do_log "-- Oldpid: $oldpid"
  if sudo kill -0 ${oldpid} 2>/dev/null; then
    do_exit_error "Another process is started (${oldpid})"
  else
    echo $1 > ${PIDFILE} || do_exit_error "Can not save pidfile ${PIDFILE}"
    do_log "Pidfile created: ${PIDFILE} (${1})"
    return 0
  fi
}


