
### Podman vs Docker

2. Networking between containers
Docker's default bridge lets containers find each other by name. Podman needs a shared network:

```bash
# Create a network
podman network create mynet

# Run containers on it
podman run --network mynet --name db postgres
podman run --network mynet --name app myapp  # can reach "db" by name
```

3. No daemon
Podman runs containers directly (no background daemon). This means:

No docker events stream
Containers don't auto-restart after reboot unless you enable systemd services for them
podman system service can emulate the Docker socket if something needs it


4. Rootless by default
Generally good, but occasionally causes permission issues with volume mounts:

```bash
# If you get permission denied on mounted volumes
podman run --userns=keep-id -v ~/data:/data ...
```

5. macOS-specific
Volumes are going through the VM, so paths must be accessible to the Podman machine:

```bash
# May need to explicitly share directories
podman machine init --volume ~/code:~/code
```

6. Socket location

Some tools expect /var/run/docker.sock:
`export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`

For your repack script, just change docker run to podman run—should work as-is.

### Output from `podman machine init`

```bash
Machine init complete
To start your machine run:

        podman machine start

Starting machine "podman-machine-default"

This machine is currently configured in rootless mode. If your containers
require root permissions (e.g. ports < 1024), or if you run into compatibility
issues with non-podman clients, you can switch using the following command:

        podman machine set --rootful

API forwarding listening on: /var/folders/1s/d4k8cbx5437g36_5bgz1ct880000gn/T/podman/podman-machine-default-api.sock

The system helper service is not installed; the default Docker API socket
address can't be used by podman. If you would like to install it, run the following commands:

        sudo /opt/homebrew/Cellar/podman/5.7.0/bin/podman-mac-helper install
        podman machine stop; podman machine start

You can still connect Docker API clients by setting DOCKER_HOST using the
following command in your terminal session:

        export DOCKER_HOST='unix:///var/folders/1s/d4k8cbx5437g36_5bgz1ct880000gn/T/podman/podman-machine-default-api.sock'

Machine "podman-machine-default" started successfully
```
