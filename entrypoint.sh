#!/usr/bin/env bash

mkdir -p "/var/log/vsftpd"
ENTRYPOINT_LOGFILE="/var/log/vsftpd/entrypoint.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') - entrypoint.sh started" >> "${ENTRYPOINT_LOGFILE}"

# Default config path if VSFTPD_CONF is not set
: "${VSFTPD_CONF:=/etc/vsftpd/vsftpd.conf}"

##
# Generate a random sixteen-character
# string of alphabetical characters
randname() {
  local -x LC_ALL=C
  tr -dc '[:lower:]' < /dev/urandom |
    dd count=1 bs=16 2>/dev/null
}

setfolderpermissions() {
  if [[ $# -ne 2 ]] || [[ ! -e "${2}" ]] || [[ -z "$(getent passwd "${1}")" ]]; then
    echo "Set the permissions on a folder based on a user and it's associated group."
    echo "Usage: setfolderpermissions <username> <folder>"
    return 1
  fi

  # get the user's group to use when chowning the home directory
  usergroupid="$(getent passwd "${1}" | cut -d':' -f4)"
  usergroup="$(getent group "${usergroupid}" | cut -d':' -f1)"

  echo "Chown: ${username}:${usergroup} (${usergroupid}) ${2}" >> "${ENTRYPOINT_LOGFILE}"
  chown "${username}:${usergroup}" "${2}"
}

createuser() {
  if [[ $# -lt 1 ]] || [[ $# -gt 3 ]]; then
    echo "Creates a system user (and group) from the given parameter if they don't exist."
    echo "Usage: createuser <id> [<name>] [<home_dir>] OR"
    echo "       createuser <name> [<home_dir>]"
    return 1
  fi

  local home_dir=""
  if [[ $# -eq 3 ]]; then
    home_dir="${3}"
  fi

  # check if we were given a numeric ID
  if [[ "${1}" =~ ^[0-9]+$ ]]; then
    # We have a numeric UID
    local target_uid="${1}"

    # Determine username: use provided name if available, otherwise generate one
    if [[ ! -z "${2}" ]]; then
      username="${2}"
    else
      username=$(randname)
    fi

    # Check if a user with this exact username already exists
    if [[ ! -z "$(getent passwd "${username}")" ]]; then
      # User with this name exists, just return it
      homedir="$(getent passwd "${username}" | cut -d':' -f6)"
      if [[ ! -z "${homedir}" ]] && [[ ! -e "${homedir}" ]]; then
        mkdir -p "${homedir}"
        chmod 755 "${homedir}"
      fi
      setfolderpermissions "${username}" "${homedir}"
      echo "${username}"
      return 0
    fi

    # check if a group with the given ID exists and create one if not
    groupid="$(getent group "${target_uid}" | cut -d':' -f3)"
    if [[ -z "${groupid}" ]]; then
      # Use groupadd without --system to avoid SYS_GID_MAX warnings for GIDs > 999
      groupadd --gid "${target_uid}" "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
      groupid="${target_uid}"
    fi

    # Check if a user with this UID already exists
    existing_user="$(getent passwd "${target_uid}" | cut -d':' -f1)"
    if [[ ! -z "${existing_user}" ]]; then
      # A user with this UID exists, create a new user with non-unique UID
      # This allows multiple FTP users to share the same UID for file permissions
      if [[ ! -z "${home_dir}" ]]; then
        useradd --uid="${target_uid}" --gid="${groupid}" --non-unique --home-dir "${home_dir}" --create-home "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
      else
        useradd --uid="${target_uid}" --gid="${groupid}" --non-unique "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
      fi
    else
      # No user with this UID, create normally
      # Use useradd without --system to avoid SYS_UID_MAX warnings for UIDs > 999
      if [[ ! -z "${home_dir}" ]]; then
        useradd --uid="${target_uid}" --gid="${groupid}" --home-dir "${home_dir}" --create-home "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
      else
        useradd --uid="${target_uid}" --gid="${groupid}" "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
      fi
    fi

    # Set write permissions for newly created users
    homedir="$(getent passwd "${username}" | cut -d':' -f6)"
    if [[ ! -z "${homedir}" ]] && [[ -e "${homedir}" ]]; then
      chmod 755 "${homedir}"
    fi
  else
    # we were given a name, not an ID
    username="${1}"

    # Check if this user already exists
    if [[ ! -z "$(getent passwd "${username}")" ]]; then
      homedir="$(getent passwd "${username}" | cut -d':' -f6)"
      if [[ ! -z "${homedir}" ]] && [[ ! -e "${homedir}" ]]; then
        mkdir -p "${homedir}"
        chmod 755 "${homedir}"
      fi
      setfolderpermissions "${username}" "${homedir}"
      echo "${username}"
      return 0
    fi

    groupid="$(getent group "${1}" | cut -d':' -f3)"
    if [[ -z "${groupid}" ]]; then
      groupadd --system "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
      groupid="$(getent group "${username}" | cut -d':' -f3)"
    fi

    # make sure a user does not exist with the given group ID before setting
    # that user's UID to be the same as the group ID. If one does exist, we
    # just create a user with an automatic UID but assign the GID to be the
    # same as the group ID we identified above.
    if [[ ! -z "$(getent passwd "${groupid}")" ]]; then
      useradd --system --gid="${groupid}" "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
    else
      useradd --system --uid="${groupid}" --gid="${groupid}" "${username}" >> "${ENTRYPOINT_LOGFILE}" 2>&1
    fi

    # Set write permissions for newly created users
    homedir="$(getent passwd "${username}" | cut -d':' -f6)"
    if [[ ! -z "${homedir}" ]] && [[ -e "${homedir}" ]]; then
      chmod 755 "${homedir}"
    fi
  fi

  # write out the username to be captured
  echo "${username}"
}

setftpconfigsetting() {
  if [[ $# -ne 3 ]] || [[ ! -e "${3}" ]]; then
    echo "Set an FTP configuration setting in the given file."
    echo "Usage: setftpconfigsetting <setting_name> <setting_value> <config_file>"
    return 1
  fi

  if [[ -z "$(grep -m1 -Gi "^${1}=" "${3}")" ]]; then
    echo "${1}=${2}" >> "${3}"
  else
    sed -i "s~^${1}=.*~${1}=${2}~" "${3}"
  fi
}

# Track if any VSFTPD_CONF_* variables were found
vsftpd_conf_count=0

# Iterate over env and apply VSFTPD_CONF_* settings
while IFS='=' read -r env_name env_value; do
  case "${env_name}" in
    VSFTPD_CONF_*)
      if [[ ${vsftpd_conf_count} -eq 0 ]]; then
        echo ""
        echo " VSFTPD CONFIGURATION SETTINGS"
        echo " ------------------------------"
      fi
      key="${env_name#VSFTPD_CONF_}"      # strip prefix
      key="${key,,}"                      # to lowercase (bash-specific)
      setftpconfigsetting "${key}" "${env_value}" "${VSFTPD_CONF}"
      echo " . ${key}=${env_value}"
      ((vsftpd_conf_count++))
      ;;
  esac
done < <(env)

if [[ ${vsftpd_conf_count} -gt 0 ]]; then
  echo ""
fi

# Backward compatibility for PASV_ADDRESS
# existing explicit pasv_address setting can now be dropped or kept; if you keep it,
# it will be overridden by VSFTPD_CONF_PASV_ADDRESS, if present.
setftpconfigsetting "pasv_address" "${PASV_ADDRESS}" "${VSFTPD_CONF}"

# make sure the passwd file exists
touch "${PASSWD_FILE}"

cat << EOB
 *************************************************
 *                                               *
 *  Docker image: alexs77/vsftpd                 *
 *  https://github.com/alexs77/docker-vsftpd     *
 *                                               *
 *************************************************

 SERVER SETTINGS
 ---------------
 . Log file: ${LOG_FILE}
 . Redirect vsftpd log to STDOUT: No.
EOB

for VARIABLE in $(env); do
  if [[ "${VARIABLE}" =~ ^VSFTPD_USER_[[:digit:]]+=.*$ ]]; then

    # remove VSFTPD_USER_:digit:= from beginning of variable
    VARIABLE="$(echo "${VARIABLE}" | cut -d'=' -f2)"

    if [[ "$(echo "${VARIABLE}" | awk -F ':' '{ print NF }')" -ne 4 ]]; then
      echo "'${VARIABLE}' user has invalid syntax. Skipping."
      continue
    fi

    VSFTPD_USER_NAME="$(echo "${VARIABLE}" | cut -d':' -f1)"
    VSFTPD_USER_PASS="$(echo "${VARIABLE}" | cut -d':' -f2)"
    VSFTPD_USER_ID="$(echo "${VARIABLE}" | cut -d':' -f3)"
    VSFTPD_USER_HOME_DIR="$(echo "${VARIABLE}" | cut -d':' -f4)"

    if [[ -z "${VSFTPD_USER_NAME}" ]] || [[ -z "${VSFTPD_USER_PASS}" ]]; then
      echo "'${VARIABLE}' is missing a username or password. Skipping."
      continue
    fi

    # add the user credentials to the vsftpd.passwd file
    entry="${VSFTPD_USER_NAME}:$(openssl passwd -1 "${VSFTPD_USER_PASS}")"
    sedr="s~^${VSFTPD_USER_NAME}:.*~${entry}~"

    # check if the user exists already in the file
    if [[ ! -z "$(grep -G -i "^${VSFTPD_USER_NAME}:" "${PASSWD_FILE}")" ]]; then
      sed -i "${sedr}" "${PASSWD_FILE}"
    else
      printf "%s:%s\n" "${VSFTPD_USER_NAME}" "$(openssl passwd -1 "${VSFTPD_USER_PASS}")" >> "${PASSWD_FILE}"
    fi

    USER_CONFIG_FILE="${USER_CONFIG_DIR}/${VSFTPD_USER_NAME}"

    cp "${DEFAULT_USER_CONFIG}" "${USER_CONFIG_FILE}"

    # pull the default username from the config file
    username="$(grep -Gi '^guest_username=' "${USER_CONFIG_FILE}" | cut -d'=' -f2)"

    # set username to default if it's still not set to anything
    if [[ -z "${username}" ]]; then
      username="ftp"
    fi

    # make sure the user ID is actually a number before setting it
    if [[ "${VSFTPD_USER_ID}" =~ ^[0-9]+$ ]] ; then
      username="$(createuser "${VSFTPD_USER_ID}" "${VSFTPD_USER_NAME}" "${VSFTPD_USER_HOME_DIR}")"
    else
      # make sure a system user exists for the username
      # that the new user is supposed to operate as.
      username="$(createuser "${username}")"

      VSFTPD_USER_ID="$(getent passwd "${username}" | cut -d':' -f3)"
    fi

    setftpconfigsetting "guest_username" "${username}" "${USER_CONFIG_FILE}"

    # ensure FTP root exists if explicitly set
    if [[ -n "${VSFTPD_USER_HOME_DIR}" ]]; then
      # get owning group for the mapped system user
      user_gid="$(getent passwd "${username}" | cut -d':' -f4)"
      user_group="$(getent group "${user_gid}" | cut -d':' -f1)"

      [[ ! -d "${VSFTPD_USER_HOME_DIR}" ]] && install -d -m 0755 -o "${username}" -g "${user_group}" "${VSFTPD_USER_HOME_DIR}"

      # always set local_root to the env value
      setftpconfigsetting "local_root" "${VSFTPD_USER_HOME_DIR}" "${USER_CONFIG_FILE}"
    else
      usersubtoken="$(cat "${USER_CONFIG_FILE}" "${VSFTPD_CONF}" | grep -m1 -Gi "^user_sub_token=" | cut -d'=' -f2)"
      VSFTPD_USER_HOME_DIR="$(cat "${USER_CONFIG_FILE}" "${VSFTPD_CONF}" | grep -m1 -Gi "^local_root=" | cut -d'=' -f2)"

      if [[ -n "${usersubtoken}" ]]; then
        VSFTPD_USER_HOME_DIR="$(echo "${VSFTPD_USER_HOME_DIR}" | sed "s/${usersubtoken}/${VSFTPD_USER_NAME}/")"
      fi
    fi

    # make sure the virtual home directory exists
    # Get the user's actual group (may differ from username when sharing UIDs)
    user_gid="$(getent passwd "${username}" | cut -d':' -f4)"
    user_group="$(getent group "${user_gid}" | cut -d':' -f1)"

    if [[ ! -d "${VSFTPD_USER_HOME_DIR}" ]]; then
      mkdir -p "${VSFTPD_USER_HOME_DIR}"
      chown "${username}:${user_group}" "${VSFTPD_USER_HOME_DIR}"
      chmod 755 "${VSFTPD_USER_HOME_DIR}"
    else
      # Directory already exists, set permissions anyway
      chown "${username}:${user_group}" "${VSFTPD_USER_HOME_DIR}"
      chmod 755 "${VSFTPD_USER_HOME_DIR}"
    fi

cat << EOB
 USER SETTINGS
 ---------------
 . FTP User: ${VSFTPD_USER_NAME}
 . System User: ${username}
 . System UID: ${VSFTPD_USER_ID}
 . FTP Home Dir: ${VSFTPD_USER_HOME_DIR}
EOB

  fi
done

# Trap code borrowed from https://github.com/panubo/docker-vsftpd/blob/master/entry.sh
function vsftpd_stop() {
  echo "Received SIGINT or SIGTERM. Shutting down vsftpd"
  # Get PID
  pid=$(cat /var/run/vsftpd/vsftpd.pid)
  # Set TERM
  kill -SIGTERM "${pid}"
  # Wait for exit
  wait "${pid}"
  # All done.
  echo "Done"
}

if [[ "${1}" == "vsftpd" ]]; then
  trap vsftpd_stop SIGINT SIGTERM
  echo "Running ${@}"
  "${@}" &
  pid="$!"
  echo "${pid}" > /var/run/vsftpd/vsftpd.pid
  wait "${pid}" && exit $?
else
  exec "${@}"
fi
