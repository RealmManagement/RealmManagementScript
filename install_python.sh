#!/bin/bash






RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'

log_info() {
    echo -e "${CYAN}[INFO]${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $1"
}


install_on_debian() {
    log_info "Detected Debian-based system."
    log_info "Updating package lists..."
    apt-get update -y

    log_info "Installing prerequisites..."
    apt-get install -y software-properties-common wget

    log_info "Adding deadsnakes PPA for modern Python versions..."
    if ! add-apt-repository -y ppa:deadsnakes/ppa; then
        log_error "Failed to add deadsnakes PPA. Please check your system's network configuration or repository settings."
        exit 1
    fi
    
    log_info "Updating package lists after adding PPA..."
    apt-get update -y

    log_info "Installing Python 3.11 and required modules (venv, dev)..."
    if ! apt-get install -y python3.11 python3.11-venv python3.11-dev; then
        log_error "Failed to install Python 3.11. The PPA might not support your OS version."
        exit 1
    fi

    log_success "Python 3.11 has been installed successfully."
}


install_on_rhel() {
    log_info "Detected RHEL-based system."
    log_info "Installing development tools and prerequisites..."
    yum groupinstall -y "Development Tools"
    yum install -y gcc openssl-devel bzip2-devel libffi-devel zlib-devel wget xz-devel

    log_info "Downloading Python 3.11.9 source..."
    cd /tmp
    if ! wget https://www.python.org/ftp/python/3.11.9/Python-3.11.9.tar.xz; then
        log_error "Failed to download Python source. Please check your network."
        exit 1
    fi

    tar -xf Python-3.11.9.tar.xz
    cd Python-3.11.9

    log_info "Configuring and compiling Python from source. This may take a while..."
    ./configure --enable-optimizations

    make altinstall

    if ! /usr/local/bin/python3.11 -c "print('Installation successful')"; then
        log_error "Python 3.11 installation from source appears to have failed."
        exit 1
    fi

    log_success "Python 3.11 has been compiled and installed to /usr/local/bin/python3.11"
}


if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root." 
   exit 1
fi

if command -v apt-get &>/dev/null; then
    install_on_debian
elif command -v yum &>/dev/null; then
    install_on_rhel
else
    log_error "Unsupported Linux distribution. This script supports Debian/Ubuntu and RHEL/CentOS."
    exit 1
fi

log_info "Python installation process finished."
