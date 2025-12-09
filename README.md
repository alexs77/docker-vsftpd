# `vsftpd` FTP Server for Docker

**Note on Security:** This container has been developed primarily
for **local and development environments** and should not be used in
a production environment without rigorous security review and
customisation.

This Docker image provides a **vsftpd** server, incorporating the
following core features:

- Based on the **`debian:bookworm-slim`** image.
- Support for **Virtual Users**, allowing the specification of a
    custom home directory (`local_root`) and associated system user
    ID (`FTP_UID`).
- **Passive Mode (PASV) only** - Active FTP is completely disabled
  for enhanced security.

The pre-built image is available on Docker Hub at
[`alexs77/vsftpd`](https://hub.docker.com/r/alexs77/vsftpd).

## Attribution

This work is based on the foundation laid by
[wildscamp/docker-vsftpd](https://github.com/wildscamp/docker-vsftpd).
For reference, their Docker registry page is available at
[`wildscamp/vsftpd`](https://hub.docker.com/r/wildscamp/vsftpd/).

## Table of Contents

- [`vsftpd` FTP Server for Docker](#vsftpd-ftp-server-for-docker)
  - [Attribution](#attribution)
  - [Table of Contents](#table-of-contents)
  - [Configuration](#configuration)
    - [Environment Variables](#environment-variables)
      - [`VSFTPD_USER_[0-9]+`](#vsftpd_user_0-9)
        - [Examples](#examples)
        - [Caveats](#caveats)
      - [`VSFTPD_CONF_*`](#vsftpd_conf_)
        - [Examples](#examples-1)
      - [`VSFTPD_CONF`](#vsftpd_conf)
      - [`PASV_ADDRESS`](#pasv_address)
        - [Common Values](#common-values)
      - [`PASV_MIN_PORT`](#pasv_min_port)
      - [`PASV_MAX_PORT`](#pasv_max_port)
  - [Ports](#ports)
  - [Volumes](#volumes)
    - [Logging](#logging)

## Configuration

This image supports run-time configuration via standard
**environment variables**.

### Environment Variables

#### `VSFTPD_USER_[0-9]+`

These are **compound variables** that enable the addition of an
arbitrary number of virtual FTP users.

- **Accepted format:** A string in the format
    `<username>:<password>:<system_uid>:<ftp_root_dir>`.
- **Description:** The `<system_uid>` and `<ftp_root_dir>`
    parameters are optional, but the separating colons (`:`) must be
    maintained. If the system user ID is omitted, it defaults to the
    UID of the built-in `ftp` account (`104`). If the root directory
    is omitted, it defaults to `/home/virtual/<username>`.

##### Examples

- `VSFTPD_USER_1=hello:world::` - Creates an FTP user **hello** with
    the password **world**. The system user's UID will default to
    `104`, and the FTP root directory will be `/home/virtual/hello`.
- `VSFTPD_USER_1=user1:docker:33:` - Creates an FTP user **user1**
    with the password **docker**. The system user's UID will be
    **33**. If a system user with this ID already exists, the FTP
    user will be mapped to it. The FTP root directory defaults to
    `/home/virtual/user1`.
- `VSFTPD_USER_1=mysql:mysql:999:/srv/ftp/mysql` - Creates an FTP
    user **mysql** with the password **mysql**. The system user's
    UID is **999**, and the FTP root directory is explicitly set to
    `/srv/ftp/mysql`.

##### Caveats

- **Reserved Username:** vsftpd applies special handling to the FTP
    username `ftp`. It is therefore recommended to avoid using this
    name when defining a virtual FTP user.
- **Writable Root:** The container configures
    `allow_writeable_chroot=YES` in the default user configuration.

#### `VSFTPD_CONF_*`

These variables allow you to set arbitrary vsftpd configuration
options without modifying configuration files.

- **Pattern:** Any environment variable prefixed with `VSFTPD_CONF_`
    will be automatically converted to a vsftpd configuration
    directive.
- **Processing:** The prefix `VSFTPD_CONF_` is stripped, the
    remaining name is converted to lowercase, and the result is
    written to the vsftpd configuration file.
- **Target file:** The configuration file path is determined by the
    `VSFTPD_CONF` variable (defaults to `/etc/vsftpd/vsftpd.conf`).

##### Examples

- `VSFTPD_CONF_DUAL_LOG_ENABLE=YES` - Sets `dual_log_enable=YES` in
    the vsftpd configuration, enabling dual logging mode.
- `VSFTPD_CONF_MAX_CLIENTS=50` - Sets `max_clients=50`, limiting the
    maximum number of simultaneous clients.
- `VSFTPD_CONF_IDLE_SESSION_TIMEOUT=600` - Sets
    `idle_session_timeout=600`, terminating idle sessions after 10
    minutes.
- `VSFTPD_CONF_WRITE_ENABLE=NO` - Sets `write_enable=NO`, creating a
    read-only FTP server.

**Note:** These settings are applied during container startup and
will override any existing values in the configuration file.

#### `VSFTPD_CONF`

- **Default value:** `/etc/vsftpd/vsftpd.conf`
- **Accepted values:** A valid file path within the container.
- **Description:** Specifies the vsftpd configuration file to which
    `VSFTPD_CONF_*` variables will write their settings. This allows
    you to target a custom configuration file if needed.

#### `PASV_ADDRESS`

- **Accepted values:** The DNS name or IP address used by the FTP
    client to connect to this container.
- **Description:** This variable instructs vsftpd as to which
    address it should advertise to clients for passive mode data
    connections. Setting an IP address is recommended, as the
    container's DNS resolution may not be identical to the Docker
    host's.
- **Notes:**
  - This parameter is **required** for proper FTP operation since
    only passive mode is supported. vsftpd will automatically
    advertise the internal Docker IP of the interface on which the
    connection was received, which is usually unreachable from the
    client host.
  - It used to be a dedicated environment variable, but can now also
    be set via `VSFTPD_CONF_PASV_ADDRESS` for consistency with other
    vsftpd settings.

##### Common Values

| Environment | IP | Comment |
| :--- | :--- | :--- |
| Docker for Windows | `10.0.75.1` | Default Hyper-V host IP |
| boot2docker | `192.168.99.100` | Default `docker-machine` IP |

#### `PASV_MIN_PORT`

- **Default value:** `30000`
- **Accepted values:** An integer lower than `PASV_MAX_PORT`.
- **Description:** The minimum port number to be used for passive
    connections.

#### `PASV_MAX_PORT`

- **Default value:** `30009`
- **Accepted values:** An integer higher than `PASV_MIN_PORT`.
- **Description:** The maximum port number to be used for passive
    connections.

## Ports

The container exposes the following ports:

- **Port 21/tcp:** FTP Control (Command Channel)
- **Ports 30000-30009/tcp:** Passive Mode (PASV) data ports. This
    range is defined by the default values for `PASV_MIN_PORT` and
    `PASV_MAX_PORT`.

**Note:** Active FTP mode is completely disabled. Port 20 is not
exposed or used.

When running the container, ensure all necessary ports are published
to your host machine using the `-p` flag or in your
`docker-compose.yaml`.

## Volumes

For the FTP server to be useful, a minimum of one data volume should
be mounted.

- **Data Directories:** The FTP user's root directory must be
    mounted from the host system or a named volume. For example, a
    user with `local_root=/home/virtual/user1` will require a volume
    mount at `/home/virtual/user1` inside the container.
- **Log Directory:** The container writes logs to `/var/log/vsftpd`.
    It is recommended to mount this directory to retain logs outside
    of the container lifecycle.
- **Configuration Overrides:** An individual user's configuration
    can be overridden by mounting a vsftpd configuration file to
    `/etc/vsftpd/vusers/<username>`. Global default settings can be
    overridden by mounting a file to
    `/etc/vsftpd/default_user.conf`.

### Logging

The vsftpd server writes log files to the `/var/log/vsftpd`
directory inside the container:

- **`/var/log/vsftpd/vsftpd.log`** - Main vsftpd log file containing
    FTP protocol commands, responses, and connection details (when
    `log_ftp_protocol=YES`)
- **`/var/log/vsftpd/xferlog`** - File transfer log recording all
    upload and download operations

To persist logs on the host system and enable access outside the
container, mount the log directory as a volume:
