# SageMath Container Toolkit
A clean starting point for running SageMath workflows inside Docker and orchestrating them with run_sage_and_notify.sh.

## Prerequisites
- Docker Engine ≥ 20.x installed and running
- Bash 4+ (the helper script uses Bash features)
- Optional: .env file with any API keys or notification settings consumed by run_sage_and_notify.sh

## Repository Layout
- Dockerfile or docker/Dockerfile — SageMath runtime image definition
- run_sage_and_notify.sh — wrapper script that launches SageMath jobs and sends notifications
- extras/ — scripts that I created to automate tasks
- scripts/ — templates and versions of final scripts used

## Quick Start

### 1. Build the Docker Image
Replace docker/Dockerfile with the real path if it lives elsewhere.
```
docker build \
  --file docker/Dockerfile \
  --tag your-namespace/sagemath:latest \
  .
```

### 2. Run SageMath in a Container
Mount the project so SageMath can read/write notebooks or scripts.
```
docker run \
  --rm \
  --interactive \
  --tty \
  --name sagemath-runner \
  --volume "$(pwd)":/workspace \
  your-namespace/sagemath:latest \
  sage
```

## Using run_sage_and_notify.sh

### Make the Script Executable
chmod +x run_sage_and_notify.sh

### Basic Invocation
Run the script from the repository root:
`./run_sage_and_notify.sh {Name of Knot} {/path/to/knot_script.sage}`

recommendations:

`nohup ./run_sage_and_notify.sh {Name of Knot} {/path/to/knot_script.sage} 2>&1 & `

### Running Inside Docker
If the script is meant to execute inside the container, first enter the container:
`docker run --rm -it -v "$(pwd)":/workspace your-namespace/sagemath:latest /bin/bash`

Then run:
`sage /path/to/sagefile`

## Troubleshooting
- Image build fails: check the Docker build context path and that all COPY/ADD targets exist.
- Permission denied: ensure the script has execute permissions and that Docker volumes map to writable directories.

## Using NTFY
NTFY is a simple HTTP-based pub-sub notification service. You can self host the application or use their REST API for free. Filling in the `NTFY_URL` and `NTFY_TOPIC` if you are self hosting. For more information, please visit: [https://ntfy.sh](https://ntfy.sh)
