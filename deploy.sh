#!/bin/bash

# !!!!!!! User builder should be a member for sudoers (w/o pwd) and docker groups!

# this adds to log string
DESCR="BUILD_DEPLOY"

##### get main path #####
pushd `dirname $0` > /dev/null
SCRIPT_PATH=`pwd`
popd > /dev/null

##### help/usage section #####
##############################
function show_examples() {
  echo "Examples:"
  echo "  ./deploy.sh -t cp -s stage -b trunk (full deployment of stage Portal from trunk)"
  echo "  ./deploy.sh -t node -b tags/2.8_b -m build_rpms (build rpm repo for node for tags/2.8_b)"
  echo "  ./deploy.sh -t cp -m build_rpms (build rpm repo for cp for trunk but it is already done by Jenkins by SCM poll)"
  echo "  N=20160328_084300 ./deploy.sh -t cp -b tags/2.8_b -m full_cp -sr -si (full transfer and deploy of freezed Portal (tags/2.8_b) with label 20160328_084300)"
  echo "  ./deploy.sh -t node -b tags/2.8_b -m build_image (deploy Node container from tags/2.8_b without transfer to instance) [DEPRECATED]"
  echo "  ./deploy.sh -t node (full deployment of stage Node from trunk) [DEPRECATED]"
#  echo "  ./deploy.sh -m 'full' -f (free space checking for all servers)"
}
function usage() {
  echo "see documentation: https://net/display/DEV/Development+Environment"
  echo "Usage: $0 -t <cp|node> [-b <trunk|tags/1.0|tags/1.1|tags/1.2>] [-s <dev|stage|prod>] [-m <build_rpms|build_image|full|full_cp] [-c] [-f] [-sc] [-sr] [-si]" 
  echo "-b means svn branch (default: 'trunk')"
  echo "-m means mode of script usage (default: 'full')"
  echo "-s means server type (default: 'dev')"
  echo "-t means docker image type (mandatory parameter)"
  echo "-sr means skip rpms building"
  echo "-si means skip docker image building"
  show_examples
  exit 1
}

##### Options parse and processing section #####
################################################

function err_opt() {
  echo; echo "----- incorrect value for option $1 -----"; echo
  usage
}

### Set global naming for images!!!
[[ -z ${N} ]] && { echo -e "DEPLOY script: NO LABEL ('N')!\n"; N=`date +%Y%m%d_%H%M00`; }
## Main option parsing part
## first shift for option and the second after parsing next arg as probable option value
#[[ "$1" =~ ^((-{1,2})([Hh]$|[Hh][Ee][Ll][Pp])|)$ ]] && usage
while [[ $# -gt 0 ]]; do
  opt="$1"
  shift;
  current_arg="$1"
#[[ "$current_arg" =~ ^-{1,2}.* ]] && echo "WARNING: You may have left an argument blank. Double check your command." 
  case "$opt" in
    "-b"|"--branch"  ) 
      # disabled to avoid of further script support. svn_check should interrupt illegal option
      #b="$1"; [[ x"$b" == x'trunk' || x"$b" == x'tags/1.0' || x"$b" == x'tags/1.1' ]] || err_opt $opt 
      b="$1";
      shift;;
    "-m"|"--mode"    ) 
      m="$1"; [[ x"$m" == x'build_rpms' || x"$m" == x'build_image' || x"$m" == x'full' ||  x"$m" == x'full_cp' ]] || err_opt $opt
      shift;;
    "-s"|"--server"  )
      s="$1"; [[ x"$s" == x'dev' || x"$s" == x'stage' || x"$s" == x'prod' ]] || err_opt $opt
      shift;;
    "-t"|"--type"    )
      t="$1"; [[ x"$t" == x'cp' || x"$t" == x'node' ]] || err_opt $opt
      shift;;
    "-sc"|"--skip-checks" ) SC=1 ;; 
    "-sr"|"--skip-rpm"    ) SR=1 ;;
    "-si"|"--skip-image"  ) SI=1 ;;
    * )
      echo "ERROR: Invalid option: \""$opt"\"" >&2
      usage
      ;;
  esac
done
# Set missed options to default values
[[ -z "${b}" ]] && b='trunk'
[[ -z "${m}" ]] && m='full'
[[ -z "${s}" ]] && s='dev'
# Process required options
[[ -z "${t}" ]] && usage
#if [[ -z "${s}" && "${m}" != 'build_rpms' ]] && [[ -z "${s}" && "${m}" != 'build_image' ]] || [ -z "${t}" ] || [ -z "${b}" ]; then
[[ -z "${b}" ]] && b='trunk'
##################################################

##### Connect conf and lib, Checkers Section #####
##################################################
source ${SCRIPT_PATH}/deploy_conf.sh
source ${SCRIPT_PATH}/deploy_lib.sh

# logfiles check
check_logfiles
#if [[ ${m} != 'build_rpms' ]]; then
  # check pid
  do_log "-- Checking pid"
  create_pid $$
#fi

#########                        ##########
#########  PROCESSING FUNCTIONS  ##########
#########                        ##########

###########################################
############ Checkers Section #############
###########################################
# checkers are logged
function process_checkers() {
  [[ -z ${SC} ]] || { do_log "Option 'Skip Checkers' set, skipping..."; return 0; }
  # Free space check on local builder server and remote cp instance
  check_space_and_cleanup 'builder' || return 1 
  check_space_and_cleanup "${s}" || return 1

##  if [[ ${b} == 'trunk' ]]; then
    # check svn specs
    check_svn_specs
    # check svn sources
    check_svn_sources
    # check svn packages (cni etc)
    check_svn_packages
##  else
    # check svn specs all
##    check_svn_specs_all
##  fi
}
############################################
########### Process repo Section ###########
############################################
function process_repo() {
  do_log "-- Start processing repo ${RPM_REPO_BASEARCH}"

  # check rpm repo, create it if not exist (common for cp and node)
  check_rpm_repo
  # Create symlink to rpms for yum repo
  if [[ ! -L ${REPO_DIR_BASEARCH} ]]; then
    do_log "-- Creating symlink to rpms for yum repo (${REPO_DIR_BASEARCH})"
    ln -s ${RPM_DIR_BASEARCH} ${REPO_DIR_BASEARCH} || do_exit_error "Can not create yum repo at ${RPM_REPO_BASEARCH}" 1
  fi
}
############################################
############ Build RPMs Section ############
############################################
function process_rpmbuild() {
  [[ -z ${SR} ]] || { do_log "Option 'Skip RPMS processing' set, skipping..."; return 0; }
  do_log "-- Start building rpms"
  do_log "RPM_DIR_BASEARCH: ${RPM_DIR_BASEARCH}; BUILD_DIR: ${BUILD_DIR}"
  do_log "SVN URL: $svn_url"
  export BUILD_DIR=${BUILD_DIR}
  [[ -z ${specs_excluded} ]] && specs_excluded='NONE' # needed for correct egrep work
  spec_files=`find $svn_dir_specs -iname "*.spec" | egrep -iv ${specs_excluded}`
  for spec_file in $spec_files; do
    do_log "build $spec_file"
    rpmb -bb $spec_file || do_exit_error "Can not build package for $spec_file" 1
  done

  # Build repo
  do_log "-- Start building repository in ${RPM_DIR_BASEARCH}"
  [[ -d ${RPM_DIR_BASEARCH} ]] && createrepo ${RPM_DIR_BASEARCH} || do_exit_error "Can not create repository at ${RPM_DIR_BASEARCH}" 1
  ### deprecated noarch
  [[ -d ${RPM_DIR_NOARCH} ]] && createrepo ${RPM_DIR_NOARCH} || do_log "Warning! Can not create repository at ${RPM_DIR_NOARCH}, but it is deprecated functionality"

  # process repo dirs and files
  do_log "-- Process RPM repository"
  process_repo || do_exit_error "Function process_repo failed" 1

  # exit mode
  if [[ ${m} == 'build_rpms' ]]; then
    do_exit_ok "--- Mode ${m} enabled, deployment complete"
  fi
}
############################################
######## Build Docker Image Section ########
############################################
function process_docker_images() {
  [[ -z ${SI} ]] || { do_log "Option 'Skip Docker Images processing' set, skipping..."; return 0; }

  # check dockerfiles svn
  check_svn_dockerfiles
  # build
  do_log "-- Start building Docker Image"
  docker build --rm --no-cache=true -t ${D_IMAGE} ${svn_dir_docker} || do_exit_error "Can not build Docker Image" 1
  do_log "-- ${D_IMAGE} successfully built. Start saving image"
  docker save ${D_IMAGE} > ${fs_img_tar_build} || do_exit_error "Can not save Docker Image" 1
  do_log "-- ${fs_img_tar_build} successfully saved"
  # compress
  do_log "-- gzip image ${fs_img_tar_build}"
  gzip ${fs_img_tar_build} || do_exit_error "Can not gzip Docker Image" 1
  # create symlink to latest
  do_log "-- Updating symlink ${fs_img_latest_build}"
  ln -sf ${fs_img_gz_build} ${fs_img_latest_build}
  do_log "-- Link to built image: ${net_img_cp}"
  do_log "-- FYI Link to latest image: ${net_img_latest_cp}"
  # exit mode
  if [[ ${m} == 'build_image' ]]; then
    do_exit_ok "--- Mode ${m} enabled, deployment complete"
  fi
}
############################################
########## Transfer Docker Image ###########
############################################
function transfer_and_rdeploy() {
  [[ ${s} = 'prod' ]] && continue_yn "Do you want to upload built image to server '${s}'?"
  do_log "-- Transfer saved image to '${s}' server"
  sudo scp -i ${ssh_key} ${fs_img_gz_build} ${ssh_user}@${ssh_host}:~ || do_exit_error "Can not transfer Docker Image to '${ssh_host}'" 1

  ########## Remote Deployment ############
  [[ -z ${remote_command} ]] && do_exit_ok "No remote command string provided"
  [[ ${s} = 'prod' ]] && continue_yn "Do you want to apply remote command string to server '${s}'? (command: ${remote_command})"
  do_log "-- Apply remote deployment procedures"
  for rcomm in "${remote_command[@]}"; do
    do_log "-- Applying rcommand ($rcomm)"
    local RES
    RES=$(sudo ssh -i ${ssh_key} ${ssh_user}@${ssh_host} "sudo bash -c \"${rcomm} 2>&1\" 2>&1")
    [[ $? != 0 ]] && local err=1 || local err=0
    [[ $err == 1 ]] && do_exit_error "-- Can not apply remote command (${rcomm}) to ${ssh_host}. (REMOTE RESPONSE: $RES, CODE: $err)" 1
  done
  do_log "-- Main remote deployment procedures successfully completed"
  #########################################

  # for Central Portal
  if [[ x${t} == x'cp' ]]; then
    [[ x${m} != x'full_cp' ]] && { do_log "Now login to Portal, stop old Docker Image and start the new one"; return 0; }
    do_log "-- Additional Portal deployment will be applied automatically (Warning! Low errors interception due to complex nature of modifications)"
    sudo ssh -i ${ssh_key} ${ssh_user}@${ssh_host} "sudo docker stop \$(sudo docker ps -a -q) && sudo docker start cp_${N}" || do_exit_error "Can not start new Portal container on ${s}" 1
    sleep 10
    sudo ssh -i ${ssh_key} ${ssh_user}@${ssh_host} "sudo docker exec \$(sudo docker ps -q) su -c \"cd ~/web && source ~/.bashrc && rake db:migrate && rake assets:clobber && rake assets:precompile\" PROJID" || do_exit_error "Can not apply rake tasks on ${s}" 1
    if [[ x${s} != x'prod' ]]; then
      do_log "-- Change Portal IP for creating nodes for non-production environments"
      sudo ssh -i ${ssh_key} ${ssh_user}@${ssh_host} "sudo docker exec \$(sudo docker ps -q) su -c \"cd ~/web && source ~/.bashrc && rake connector_ssh:switch_to_stage\" PROJID" || do_exit_error "Can not apply 'switch to stage' rake task on ${s}" 1
    fi 
    #sudo ssh -i ${ssh_key} ${ssh_user}@${ssh_host} "sudo docker exec \$(sudo docker ps -q) echo 1so8u1lD | sudo passwd root --stdin" || do_exit_error "Can not apply rake tasks on ${s}" 1
    # make changes in development system cp
  ###  if [[ ${s} = 'dev' ]]; then
  ###    sudo ssh -i ${ssh_key} ${ssh_user}@${ssh_host} "docker exec \$(docker ps -q) bash -c \"sed -i 's/RailsEnv production/RailsEnv development/g' /etc/httpd/conf.modules.d/02-passenger.conf && sed -i 's/RailsEnv production/RailsEnv development/g' /opt/PROJID/.bashrc && vctl restart httpd \"" || do_exit_error "Can not set development mode on ${s}" 1
  ###  fi
  fi
}
############################################
############# Post-Deployment ##############
############################################
function post_deployment() {
  if [[ ${t} = 'node' ]]; then
    if [[ ${s} = 'stage' || ${s} = 'prod' ]]; then
      do_log "-- Important deployment detected. Start notifying"
      do_log "-- Check link (${net_img_cp})"
      if [[ `wget -S --no-check-certificate --spider ${net_img_cp} 2>&1 | grep 'HTTP/1.1 200 OK'` && `wget -S --no-check-certificate --spider ${net_img_latest_md5} 2>&1 | grep 'HTTP/1.1 200 OK'` ]]; then
        MSG="Link to new image archive: ${net_img_cp}\n"
        MSG=${MSG}"Checksum: ${net_img_latest_md5}"
        echo -e ${MSG} | mailx -s "CI: New Node build (version: ${N}, ${s}) deployed" "${ANKARA_MAIL}" > /dev/null 2>&1
      else
        echo -e "Error link: ${net_img_cp}" | mailx -s "CI: WARNING! image link is not available!" "${CDM_MAIL}" > /dev/null 2>&1
      fi
    fi # ${s} check
  fi #  ${t} check
}
############################################

#########               ##########
#########   MAIN PART   ##########
#########               ##########
do_log "============= START DEPLOY SCRIPT (label: ${N}) ==============="
do_log "--- Main opts: type ${t}; server ${s}; branch: ${b}; mode: ${m}"

do_log "+++ Process checkers (free space and svn files update)"
process_checkers || do_exit_error "Function process_checkers failed" 1

do_log "+++ Process RPM builds"
do_log "--- repository last modified [$(get_last_repo_mod)] ago"
if [[ ${m} == 'build_rpms' || ${b} != 'trunk' ]]; then
  process_rpmbuild || do_exit_error "Function process_rpmbuild failed" 1
  [[ ${m} == 'build_rpms' ]] && do_exit_ok "--- Mode ${m} enabled, build complete"
else
  do_log "--- No need to build RPMS (tags case, or using regularly built repo for trunk), skipping..."
fi

do_log "+++ Process Docker image"
process_docker_images || do_exit_error "Function process_docker_images failed" 1
[[ ${m} == 'build_image' ]] && do_exit_ok "--- Mode ${m} enabled, build complete"

do_log "+++ Process Transfer and remote deployment"
transfer_and_rdeploy || do_exit_error "Function transfer_and_rdeploy failed" 1

do_log "+++ Additional operations"
post_deployment

# Finish
do_exit_ok "======== All DEPLOY SCRIPT procedures passed for ${t} (${N}) ========" 0
