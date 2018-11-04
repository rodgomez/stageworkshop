#!/usr/bin/env bash
# -x
# Dependencies: acli, ncli, dig, jq, sshpass, curl, md5sum, pgrep, wc, tr, pkill
# Please configure according to your needs

function test_dns() {
  local   _dns
  local _error=44
  local  _test=$?

  CheckArgsExist 'LDAP_HOST MY_DOMAIN_FQDN'

  _dns=$(dig +retry=0 +time=2 +short @${LDAP_HOST} dc1.${MY_DOMAIN_FQDN})

  if [[ ${_dns} != "${LDAP_HOST}" ]]; then
    log "Error ${_error}: result was ${_test}: ${_dns}"
    return ${_error}
  fi
}

function acli() {
  local _cmd

  _cmd=$*
	/usr/local/nutanix/bin/acli ${_cmd}
  # DEBUG=1 && if [[ ${DEBUG} ]]; then log "$@"; fi
}

function pe_init() {
  CheckArgsExist 'DATA_SERVICE_IP MY_EMAIL \
    SMTP_SERVER_ADDRESS SMTP_SERVER_FROM SMTP_SERVER_PORT \
    MY_CONTAINER_NAME MY_SP_NAME MY_IMG_CONTAINER_NAME \
    SLEEP ATTEMPTS'

  if [[ `ncli cluster get-params | grep 'External Data' | \
         awk -F: '{print $2}' | tr -d '[:space:]'` == "${DATA_SERVICE_IP}" ]]; then
    log "IDEMPOTENCY: Data Services IP set, skip."
  else
    log "Configure SMTP: https://sewiki.nutanix.com/index.php/Hosted_POC_FAQ#I.27d_like_to_test_email_alert_functionality.2C_what_SMTP_server_can_I_use_on_Hosted_POC_clusters.3F"
    ncli cluster set-smtp-server port=${SMTP_SERVER_PORT} \
      from-email-address=${SMTP_SERVER_FROM} address=${SMTP_SERVER_ADDRESS}
    ${HOME}/serviceability/bin/email-alerts --to_addresses="${MY_EMAIL}" \
      --subject="[pe_init:Config SMTP:alert test] `ncli cluster get-params`" \
      && ${HOME}/serviceability/bin/send-email

    log "Configure NTP"
    ncli cluster add-to-ntp-servers \
      servers=0.us.pool.ntp.org,1.us.pool.ntp.org,2.us.pool.ntp.org,3.us.pool.ntp.org

    log "Rename default container to ${MY_CONTAINER_NAME}"
    default_container=$(ncli container ls | grep -P '^(?!.*VStore Name).*Name' \
      | cut -d ':' -f 2 | sed s/' '//g | grep '^default-container-')
    ncli container edit name="${default_container}" new-name="${MY_CONTAINER_NAME}"

    log "Rename default storage pool to ${MY_SP_NAME}"
    default_sp=$(ncli storagepool ls | grep 'Name' | cut -d ':' -f 2 | sed s/' '//g)
    ncli sp edit name="${default_sp}" new-name="${MY_SP_NAME}"

    log "Check if there is a container named ${MY_IMG_CONTAINER_NAME}, if not create one"
    (ncli container ls | grep -P '^(?!.*VStore Name).*Name' \
      | cut -d ':' -f 2 | sed s/' '//g | grep "^${MY_IMG_CONTAINER_NAME}" > /dev/null 2>&1) \
      && log "Container ${MY_IMG_CONTAINER_NAME} exists" \
      || ncli container create name="${MY_IMG_CONTAINER_NAME}" sp-name="${MY_SP_NAME}"

    # Set external IP address:
    #ncli cluster edit-params external-ip-address=${MY_PE_HOST}

    log "Set Data Services IP address to ${DATA_SERVICE_IP}"
    ncli cluster edit-params external-data-services-ip-address=${DATA_SERVICE_IP}
  fi
}

function network_configure() {
  # From this point, we assume according to SEWiki:
  # IP Range: ${HPOC_PREFIX}.0/25
  # Gateway: ${HPOC_PREFIX}.1
  # DNS: 10.21.253.10,10.21.253.11
  # DHCP Pool: ${HPOC_PREFIX}.50 - ${HPOC_PREFIX}.120

  CheckArgsExist 'MY_PRIMARY_NET_NAME MY_PRIMARY_NET_VLAN MY_SECONDARY_NET_NAME MY_SECONDARY_NET_VLAN MY_DOMAIN_NAME HPOC_PREFIX LDAP_HOST'

  if [[ ! -z `acli "net.list" | grep ${MY_SECONDARY_NET_NAME}` ]]; then
    log "IDEMPOTENCY: ${MY_SECONDARY_NET_NAME} network set, skip"
  else
    log "Remove Rx-Automation-Network if it exists..."
    acli "-y net.delete Rx-Automation-Network"

    log "Create primary network: Name: ${MY_PRIMARY_NET_NAME}"
    # log "VLAN: ${MY_PRIMARY_NET_VLAN}"
    # log "Subnet: ${HPOC_PREFIX}.1/25"
    # log "Domain: ${MY_DOMAIN_NAME}"
    # log "Pool: ${HPOC_PREFIX}.50 to ${HPOC_PREFIX}.125"
    acli "net.create ${MY_PRIMARY_NET_NAME} vlan=${MY_PRIMARY_NET_VLAN} ip_config=${HPOC_PREFIX}.1/25"
    acli "net.update_dhcp_dns ${MY_PRIMARY_NET_NAME} servers=${LDAP_HOST},10.21.253.10 domains=${MY_DOMAIN_NAME}"
    acli "net.add_dhcp_pool ${MY_PRIMARY_NET_NAME} start=${HPOC_PREFIX}.50 end=${HPOC_PREFIX}.125"

    if [[ ${MY_SECONDARY_NET_NAME} ]]; then
      log "Create secondary network: Name: ${MY_SECONDARY_NET_NAME}"
      # log "VLAN: ${MY_SECONDARY_NET_VLAN}"
      # log "Subnet: ${HPOC_PREFIX}.129/25"
      # log "Domain: ${MY_DOMAIN_NAME}"
      # log "Pool: ${HPOC_PREFIX}.132 to ${HPOC_PREFIX}.253"
      acli "net.create ${MY_SECONDARY_NET_NAME} vlan=${MY_SECONDARY_NET_VLAN} ip_config=${HPOC_PREFIX}.129/25"
      acli "net.update_dhcp_dns ${MY_SECONDARY_NET_NAME} servers=${LDAP_HOST},10.21.253.10 domains=${MY_DOMAIN_NAME}"
      acli "net.add_dhcp_pool ${MY_SECONDARY_NET_NAME} start=${HPOC_PREFIX}.132 end=${HPOC_PREFIX}.253"
    fi
  fi
}

function authentication_source() {
  local   _attempts
  local      _error=13
  local       _loop
  local     _result
  local      _sleep
  local       _test
  local         _vm

  CheckArgsExist 'LDAP_SERVER MY_DOMAIN_FQDN SLEEP MY_IMG_CONTAINER_NAME'

  if [[ -z ${LDAP_SERVER} ]]; then
    log "Error ${_error}: please provide a choice for authentication server."
    exit ${_error}
  fi

  case "${LDAP_SERVER}" in
    'ActiveDirectory')
      log "Manual setup = https://github.com/nutanixworkshops/labs/blob/master/setup/active_directory/active_directory_setup.rst"
      ;;
    'AutoDC')
      test_dns; _result=$?

      if (( ${_result} == 0 )); then
        log "${LDAP_SERVER}.IDEMPOTENCY: dc1.${MY_DOMAIN_FQDN} set, skip. ${_result}"
      else
        log "${LDAP_SERVER}.IDEMPOTENCY failed, no DNS record dc1.${MY_DOMAIN_FQDN}"

       _error=12
        _loop=0
       _sleep=${SLEEP}

        repo_test AUTODC_IMAGES[@]

        if (( `source /etc/profile.d/nutanix_env.sh && acli image.list | grep ${LDAP_SERVER} | wc --lines` == 0 )); then
          log "Import ${LDAP_SERVER} image from ${SOURCE_URL}..."
          acli image.create ${LDAP_SERVER} image_type=kDiskImage wait=true \
            container=${MY_IMG_CONTAINER_NAME} source_url=${SOURCE_URL}
        else
          log "Image already found, skipping ${LDAP_SERVER} import."
        fi

        # TODO: detect AUTH image ready, else...
        log "Create ${LDAP_SERVER} VM based on ${LDAP_SERVER} image"
        acli "vm.create ${LDAP_SERVER} num_vcpus=2 num_cores_per_vcpu=1 memory=2G"
        # vmstat --wide --unit M --active # suggests 2G sufficient, was 4G
        acli "vm.disk_create ${LDAP_SERVER} cdrom=true empty=true"
        acli "vm.disk_create ${LDAP_SERVER} clone_from_image=${LDAP_SERVER}"
        acli "vm.nic_create ${LDAP_SERVER} network=${MY_PRIMARY_NET_NAME} ip=${LDAP_HOST}"

        log "Power on ${LDAP_SERVER} VM..."
        acli "vm.on ${LDAP_SERVER}"

        _attempts=20
            _loop=0
           _sleep=7

        while true ; do
          (( _loop++ ))
          _test=$(remote_exec 'SSH' 'LDAP_SERVER' 'systemctl show samba-ad-dc --property=SubState')

          if [[ "${_test}" == "SubState=running" ]]; then
            log "${LDAP_SERVER} is ready."
            sleep ${_sleep}
            break
          elif (( ${_loop} > ${_attempts} )); then
            log "Error ${_error}: ${LDAP_SERVER} VM running: giving up after ${_loop} tries."
            _result=$(source /etc/profile.d/nutanix_env.sh \
              && for _vm in $(source /etc/profile.d/nutanix_env.sh && acli vm.list | grep ${LDAP_SERVER}) ; do acli -y vm.delete $_vm; done)
            log "Remediate by deleting the ${LDAP_SERVER} VM from PE (just attempted by this script: ${_result}) and then running acli $_"
            exit ${_error}
          else
            log "_test ${_loop}/${_attempts}=|${_test}|: sleep ${_sleep} seconds..."
            sleep ${_sleep}
          fi
        done

        log "Create Reverse Lookup Zone on ${LDAP_SERVER} VM..."
        _attempts=3
            _loop=0

        while true ; do
          (( _loop++ ))
          # TODO:130 Samba service reload better? vs. force-reload and restart
          remote_exec 'SSH' 'LDAP_SERVER' \
            "samba-tool dns zonecreate dc1 ${OCTET[2]}.${OCTET[1]}.${OCTET[0]}.in-addr.arpa && service samba-ad-dc restart" \
            'OPTIONAL'
          sleep ${_sleep}

          test_dns; _result=$?

          if (( ${_result} == 0 )); then
            log "Success: DNS record dc1.${MY_DOMAIN_FQDN} set."
            break
          elif (( ${_loop} > ${_attempts} )); then
            log "Error ${_error}: ${LDAP_SERVER}: giving up after ${_loop} tries; deleting VM..."
            acli "-y vm.delete ${LDAP_SERVER}"
            exit ${_error}
          else
            log "test_dns ${_loop}/${_attempts}=|${_result}|: sleep ${_sleep} seconds..."
            sleep ${_sleep}
          fi
        done

      fi
      ;;
    'OpenLDAP')
      log "To be documented, see https://drt-it-github-prod-1.eng.nutanix.com/mark-lavi/openldap"
      ;;
  esac
}

function pe_auth() {
  CheckArgsExist 'MY_DOMAIN_NAME MY_DOMAIN_FQDN MY_DOMAIN_URL MY_DOMAIN_USER MY_DOMAIN_PASS MY_DOMAIN_ADMIN_GROUP'

  if [[ -z `ncli authconfig list-directory name=${MY_DOMAIN_NAME} | grep Error` ]]; then
    log "IDEMPOTENCY: ${MY_DOMAIN_NAME} directory set, skip."
  else
    log "Configure PE external authentication"
    ncli authconfig add-directory \
      directory-type=ACTIVE_DIRECTORY \
      connection-type=LDAP directory-url="${MY_DOMAIN_URL}" \
      domain="${MY_DOMAIN_FQDN}" \
      name="${MY_DOMAIN_NAME}" \
      service-account-username="${MY_DOMAIN_USER}" \
      service-account-password="${MY_DOMAIN_PASS}"

    log "Configure PE role map"
    ncli authconfig add-role-mapping \
      role=ROLE_CLUSTER_ADMIN \
      entity-type=group name="${MY_DOMAIN_NAME}" \
      entity-values="${MY_DOMAIN_ADMIN_GROUP}"
  fi
}

function pe_license() {
  CheckArgsExist 'CURL_POST_OPTS MY_PE_PASSWORD'

  log "IDEMPOTENCY: Checking PC API responds, curl failures are acceptable..."
  Check_Prism_API_Up 'PC' 2 0

  if (( $? == 0 )) ; then
    log "IDEMPOTENCY: PC API responds, skip"
  else
    log "Validate EULA on PE"
    curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${MY_PE_PASSWORD} -X POST --data '{
      "username": "SE with stage_calmhow.sh",
      "companyName": "Nutanix",
      "jobTitle": "SE"
    }' https://localhost:9440/PrismGateway/services/rest/v1/eulas/accept

    log "Disable Pulse in PE"
    curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${MY_PE_PASSWORD} -X PUT --data '{
      "defaultNutanixEmail": null,
      "emailContactList": null,
      "enable": false,
      "enableDefaultNutanixEmail": false,
      "isPulsePromptNeeded": false,
      "nosVersion": null,
      "remindLater": null,
      "verbosityType": null
    }' https://localhost:9440/PrismGateway/services/rest/v1/pulse

    #echo; log "Create PE Banner Login" # TODO: for PC, login banner
    # https://portal.nutanix.com/#/page/docs/details?targetId=Prism-Central-Guide-Prism-v56:mul-welcome-banner-configure-pc-t.html
    # curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${MY_PE_PASSWORD} -X POST --data \
    #  '{type: "welcome_banner", key: "welcome_banner_status", value: true}' \
    #  https://localhost:9440/PrismGateway/services/rest/v1/application/system_data
    #curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${MY_PE_PASSWORD} -X POST --data
    #  '{type: "welcome_banner", key: "welcome_banner_content", value: "HPoC '${OCTET[2]}' password = '${MY_PE_PASSWORD}'"}' \
    #  https://localhost:9440/PrismGateway/services/rest/v1/application/system_data
  fi
}

function pc_init() {
  local _version_id

  log "IDEMPOTENCY: Checking PC API responds, curl failures are acceptable..."
  Check_Prism_API_Up 'PC' 2 0

  if (( $? == 0 )) ; then
    log "IDEMPOTENCY: PC API responds, skip."
  else
    log "Get NET_UUID,MY_CONTAINER_UUID from cluster: pc_init dependency."
    MY_NET_UUID=$(acli "net.get ${MY_PRIMARY_NET_NAME}" | grep "uuid" | cut -f 2 -d ':' | xargs)
    log "${MY_PRIMARY_NET_NAME} UUID is ${MY_NET_UUID}"
    MY_CONTAINER_UUID=$(ncli container ls name=${MY_CONTAINER_NAME} | grep Uuid | grep -v Pool | cut -f 2 -d ':' | xargs)
    log "${MY_CONTAINER_NAME} UUID is ${MY_CONTAINER_UUID}"

    NTNX_Download 'PC'

    log "Prism Central upload..."
    # TODO: Error: Software prism_central_deploy.5.9.0.1 already exists on the cluster
    ncli software upload software-type=PRISM_CENTRAL_DEPLOY \
           file-path="`pwd`/${NTNX_SOURCE_URL##*/}" \
      meta-file-path="`pwd`/${NTNX_META_URL##*/}"

    _version_id=$(cat ${NTNX_META_URL##*/} | jq -r .version_id)

    log "Delete PC sources to free CVM space..."
    rm -f ${NTNX_SOURCE_URL##*/} ${NTNX_META_URL##*/}

    log "Deploy Prism Central (typically takes 17+ minutes)..."
    # TODO:150 Parameterize DNS Servers & add secondary
    # TODO:120 make scale-out & dynamic, was: 4vCPU/16GB = 17179869184, 8vCPU/40GB = 42949672960

    HTTP_BODY=$(cat <<EOF
{
  "resources": {
    "should_auto_register":true,
    "version":"${PC_VERSION}",
    "pc_vm_list":[{
      "data_disk_size_bytes":536870912000,
      "nic_list":[{
        "network_configuration":{
          "subnet_mask":"255.255.255.128",
          "network_uuid":"${MY_NET_UUID}",
          "default_gateway":"${HPOC_PREFIX}.1"
        },
        "ip_list":["${MY_PC_HOST}"]
      }],
      "dns_server_ip_list":["${LDAP_HOST}"],
      "container_uuid":"${MY_CONTAINER_UUID}",
      "num_sockets":8,
      "memory_size_bytes":42949672960,
      "vm_name":"Prism Central ${_version_id}"
    }]
  }
}
EOF
    )
    local _test
    _test=$(curl ${CURL_POST_OPTS} --user ${PRISM_ADMIN}:${MY_PE_PASSWORD} \
      -X POST --data "${HTTP_BODY}" \
      https://localhost:9440/api/nutanix/v3/prism_central)
    #log "_test=|${_test}|"
  fi
}

function pc_configure() {
  local    _container
  local _dependencies='common.lib.sh global.vars.sh stage_calmhow_pc.sh'

  if [[ -e ${RELEASE} ]]; then
    _dependencies+=" ${RELEASE}"
  fi
  log "Send configuration scripts to PC and remove: ${_dependencies}"
  remote_exec 'scp' 'PC' "${_dependencies}" && rm -f ${_dependencies}

  _dependencies="${JQ_PACKAGE} ${SSHPASS_PACKAGE} id_rsa.pub"

  log "OPTIONAL: Send binary dependencies to PC: ${_dependencies}"
  remote_exec 'scp' 'PC' "${_dependencies}" 'OPTIONAL'

  for _container in epsilon nucalm ; do
    if [[ -e ${_container}.tar ]]; then
      log "Uploading Calm container updates in background..."
      remote_exec 'SCP' 'PC' ${_container}.tar 'OPTIONAL' &
    fi
  done

  # Execute that file asynchroneously remotely (script keeps running on CVM in the background)
  log "Launch PC configuration script"
  remote_exec 'ssh' 'PC' \
    "MY_EMAIL=${MY_EMAIL} MY_PC_HOST=${MY_PC_HOST} MY_PE_PASSWORD=${MY_PE_PASSWORD} PC_VERSION=${PC_VERSION} \
    nohup bash /home/nutanix/stage_calmhow_pc.sh >> stage_calmhow_pc.log 2>&1 &"
  log "PC Configuration complete: try Validate Staged Clusters now."
}

function nos_upgrade() {
  #this is a prototype, untried
  NTNX_Download

  ncli software upload software-type=nos \
    meta-file-path="`pwd`/${NTNX_META_URL##*/}" \
    file-path="`pwd`/${NTNX_SOURCE_URL##*/}"
}
#__main()__________

# Source Nutanix environment (PATH + aliases), then Workshop common routines + global variables
. /etc/profile.d/nutanix_env.sh
. common.lib.sh
. global.vars.sh
begin

CheckArgsExist 'MY_EMAIL MY_PE_HOST MY_PE_PASSWORD PC_VERSION'

#Dependencies 'install' 'jq' && NTNX_Download 'PC' & #attempt at parallelization

log "Adding key to PE/CVMs..." && SSH_PubKey || true & # non-blocking, parallel suitable

# Some parallelization possible to critical path; not much: would require pre-requestite checks to work!
Dependencies 'install' 'sshpass' && Dependencies 'install' 'jq' \
&& pe_license \
&& pe_init \
&& network_configure \
&& authentication_source \
&& pe_auth \
&& pc_init \
&& Check_Prism_API_Up 'PC'

if (( $? == 0 )) ; then
  pc_configure && Dependencies 'remove' 'sshpass' && Dependencies 'remove' 'jq';
  log "PC Configuration complete: Waiting for PC deployment to complete, API is up!"
  log "PE = https://${MY_PE_HOST}:9440"
  log "PC = https://${MY_PC_HOST}:9440"
  finish
else
  log "Error 18: in main functional chain, exit!"
  exit 18
fi
