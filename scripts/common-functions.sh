#!/bin/bash

# common-functions.sh - Standardized messaging and utility functions for all scripts
# Source this file in other scripts with: source "$(dirname "$0")/common-functions.sh"

# Standard color definitions
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# Standard messaging functions
print_header() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo
}

print_step() {
    echo -e "${GREEN}[STEP $1]${NC} $2"
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_note() {
    echo -e "${CYAN}[NOTE]${NC} $1"
}

print_separator() {
    echo -e "${BLUE}======================================${NC}"
}

print_next_step() {
    echo
    echo -e "${GREEN}[NEXT STEP]${NC}"
    echo "$1"
}

print_summary() {
    echo
    print_separator
    echo -e "${GREEN}✅ $1${NC}"
    print_separator
    echo
}

# Configuration loading with error handling
load_config() {
    local config_file="${1:-.env}"
    
    if [ -f "$config_file" ]; then
        source "$config_file"
        print_status "Configuration loaded from $config_file"
    else
        print_error "Configuration file not found: $config_file"
        echo "Run step-000-setup-configuration.sh first."
        exit 1
    fi
}

# Status tracking functions
update_status() {
    local step="$1"
    local status_file="${2:-.setup-status}"
    echo "${step}-completed=$(date)" >> "$status_file"
}

check_prerequisites() {
    local required_step="$1"
    local status_file="${2:-.setup-status}"
    
    if [ ! -f "$status_file" ]; then
        print_error "Setup status file not found. Run step-000-setup-configuration.sh first."
        exit 1
    fi
    
    if ! grep -q "${required_step}-completed" "$status_file"; then
        print_error "Prerequisite step $required_step not completed."
        echo "Please run the required step first."
        exit 1
    fi
}

# Progress indicator
show_progress() {
    local current="$1"
    local total="$2"
    local description="$3"
    
    local percentage=$((current * 100 / total))
    local bar_length=20
    local filled_length=$((current * bar_length / total))
    
    local bar=""
    for ((i=0; i<filled_length; i++)); do
        bar+="█"
    done
    for ((i=filled_length; i<bar_length; i++)); do
        bar+="░"
    done
    
    echo -e "${CYAN}[PROGRESS]${NC} [$bar] $percentage% - $description"
}

# Validate AWS CLI and credentials
check_aws_cli() {
    if ! command -v aws >/dev/null 2>&1; then
        print_error "AWS CLI is not installed"
        echo "Please install AWS CLI first:"
        echo "  curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\""
        echo "  unzip awscliv2.zip"
        echo "  sudo ./aws/install"
        exit 1
    fi
    
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        print_error "AWS credentials not configured"
        echo "Please configure AWS credentials first:"
        echo "  aws configure"
        exit 1
    fi
}

# Validate Docker is running
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker is not installed"
        echo "Please install Docker first or run a script that installs it."
        exit 1
    fi
    
    if ! docker ps >/dev/null 2>&1 && ! sudo docker ps >/dev/null 2>&1; then
        print_error "Docker daemon is not running"
        echo "Please start Docker:"
        echo "  sudo systemctl start docker"
        exit 1
    fi
}

# Timeout with progress
wait_with_progress() {
    local timeout="$1"
    local check_command="$2"
    local description="$3"
    local interval="${4:-5}"
    
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_command" >/dev/null 2>&1; then
            print_success "$description completed"
            return 0
        fi
        
        show_progress $elapsed $timeout "$description"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    print_error "$description timed out after $timeout seconds"
    return 1
}