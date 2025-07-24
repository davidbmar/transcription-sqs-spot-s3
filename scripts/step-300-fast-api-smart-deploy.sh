#!/bin/bash

# step-300-fast-api-smart-deploy.sh - Smart deployment for Fast API Voice Transcription

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Parse command line arguments
HEADLESS=false
USE_TAG=""
for arg in "$@"; do
    case "$arg" in
        --headless)
            HEADLESS=true
            ;;
        --tag=*)
            USE_TAG="${arg#*=}"
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --headless      Skip intro screen"
            echo "  --tag=TAG       Deploy specific image tag (e.g., --tag=fixed)"
            echo "  --help          Show this help message"
            exit 0
            ;;
    esac
done

# Function to display intro screen
show_intro() {
    clear
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}              🎤 Fast API Smart Deployment - 4 Scenarios                      ${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Quick check for existing instances to show real-time status
    RUNNING_COUNT=$(aws ec2 describe-instances \
        --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
        --region "$AWS_REGION" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output json 2>/dev/null | jq '. | flatten | length' 2>/dev/null || echo "0")
    
    STOPPED_COUNT=$(aws ec2 describe-instances \
        --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=stopped" \
        --region "$AWS_REGION" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output json 2>/dev/null | jq '. | flatten | length' 2>/dev/null || echo "0")
    
    # ECR image check - get all images with details
    ECR_IMAGES=$(aws ecr describe-images \
        --repository-name "${QUEUE_PREFIX}-fast-api-gpu" \
        --region "$AWS_REGION" \
        --query 'imageDetails[*].[imageTags[0],imageDigest,imagePushedAt,imageSizeInBytes]' \
        --output json 2>/dev/null || echo "[]")
    
    ECR_IMAGE_COUNT=$(echo "$ECR_IMAGES" | jq '. | length' 2>/dev/null || echo "0")
    
    # Scenario 1: Use existing running instances
    if [ "$RUNNING_COUNT" -gt 0 ]; then
        if [ "$RUNNING_COUNT" -eq 1 ]; then
            SCENARIO1_STATUS="${GREEN}(1 running)${NC}"
        else
            SCENARIO1_STATUS="${GREEN}($RUNNING_COUNT running)${NC}"
        fi
    else
        SCENARIO1_STATUS="${YELLOW}(none running)${NC}"
    fi
    
    # Scenario 2: Restart stopped instances
    if [ "$STOPPED_COUNT" -gt 0 ]; then
        if [ "$STOPPED_COUNT" -eq 1 ]; then
            SCENARIO2_STATUS="${GREEN}(1 stopped)${NC}"
        else
            SCENARIO2_STATUS="${GREEN}($STOPPED_COUNT stopped)${NC}"
        fi
    else
        SCENARIO2_STATUS="${YELLOW}(none stopped)${NC}"
    fi
    
    # Scenario 3: Deploy with existing image
    if [ "$RUNNING_COUNT" -gt 0 ] || [ "$STOPPED_COUNT" -gt 0 ]; then
        SCENARIO3_STATUS="${YELLOW}(instances exist)${NC}"
    elif [ "$ECR_IMAGE_COUNT" -gt 0 ]; then
        if [ "$ECR_IMAGE_COUNT" -eq 1 ]; then
            SCENARIO3_STATUS="${GREEN}(1 image ready)${NC}"
        else
            SCENARIO3_STATUS="${GREEN}($ECR_IMAGE_COUNT images ready)${NC}"
        fi
    else
        SCENARIO3_STATUS="${YELLOW}(needs image)${NC}"
    fi
    
    echo -e "${GREEN}📍 1. USE EXISTING${NC}      ${SCENARIO1_STATUS}  ${GREEN}└─ Use running instances (0s)${NC}"
    echo -e "${BLUE}🔄 2. RESTART STOPPED${NC}   ${SCENARIO2_STATUS}  ${BLUE}└─ Start stopped instances (~1-2min)${NC}"
    echo -e "${CYAN}🚀 3. DEPLOY ONLY${NC}       ${SCENARIO3_STATUS}  ${CYAN}└─ Launch with existing image (~3-5min)${NC}"
    echo -e "${YELLOW}🔨 4. BUILD & DEPLOY${NC}     ${YELLOW}(full build)${NC}      ${YELLOW}└─ Build new image + deploy (~10-15min)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}System auto-detects best scenario │ Use --headless to skip intro${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}Press any key to continue...${NC}"
    read -n 1 -s -r
    clear
}

# Load configuration first
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}[ERROR]${NC} Configuration file not found."
    exit 1
fi

# Show intro unless --headless
if [ "$HEADLESS" = false ]; then
    show_intro
fi

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🎤 Fast API Smart Deployment${NC}"
echo -e "${BLUE}======================================${NC}"
echo

# Check for existing Fast API instances
echo -e "${GREEN}[STEP 1]${NC} Scanning for existing Fast API instances..."

# Find running Fast API instances
FAST_API_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,LaunchTime,InstanceType]' \
    --output json 2>/dev/null || echo "[]")

# Flatten the nested array structure
FLATTENED_INSTANCES=$(echo "$FAST_API_INSTANCES" | jq -r 'flatten(1)')
INSTANCE_COUNT=$(echo "$FLATTENED_INSTANCES" | jq '. | length')

if [ "$INSTANCE_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Found $INSTANCE_COUNT Fast API instance(s):${NC}"
    echo
    
    # Display instances with health check
    for i in $(seq 0 $((INSTANCE_COUNT-1))); do
        INSTANCE_ID=$(echo "$FLATTENED_INSTANCES" | jq -r ".[$i][0]")
        PUBLIC_IP=$(echo "$FLATTENED_INSTANCES" | jq -r ".[$i][1]")
        LAUNCH_TIME=$(echo "$FLATTENED_INSTANCES" | jq -r ".[$i][2]")
        INSTANCE_TYPE=$(echo "$FLATTENED_INSTANCES" | jq -r ".[$i][3]")
        
        # Quick health check
        if curl -f -s --max-time 3 "http://$PUBLIC_IP:8000/health" >/dev/null 2>&1; then
            HEALTH_STATUS="${GREEN}✓ HEALTHY${NC}"
            API_URL="http://$PUBLIC_IP:8000"
        else
            HEALTH_STATUS="${YELLOW}⚠ STARTING${NC}"
            API_URL="http://$PUBLIC_IP:8000 (not ready)"
        fi
        
        echo -e "  ${CYAN}Instance $((i+1)):${NC}"
        echo -e "    ID: $INSTANCE_ID"
        echo -e "    IP: $PUBLIC_IP"
        echo -e "    Type: $INSTANCE_TYPE"
        echo -e "    Status: $HEALTH_STATUS"
        echo -e "    API: $API_URL"
        echo -e "    Launched: $LAUNCH_TIME"
        echo
    done
    
    echo -e "${GREEN}🎉 Scenario 1: USE EXISTING - Ready to use!${NC}"
    echo -e "${WHITE}No deployment needed. Use the API endpoints above.${NC}"
    
else
    echo -e "${YELLOW}⚠ No running Fast API instances found${NC}"
    echo
    
    # Check for stopped instances first
    echo -e "${GREEN}[STEP 2]${NC} Checking for stopped Fast API instances..."
    
    STOPPED_INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=tag:Type,Values=fast-api-worker" "Name=instance-state-name,Values=stopped" \
        --region "$AWS_REGION" \
        --query 'Reservations[*].Instances[*].[InstanceId,ImageId,InstanceType,LaunchTime]' \
        --output json 2>/dev/null || echo "[]")
    
    STOPPED_FLATTENED=$(echo "$STOPPED_INSTANCES" | jq -r 'flatten(1)')
    STOPPED_COUNT=$(echo "$STOPPED_FLATTENED" | jq '. | length')
    
    if [ "$STOPPED_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Found $STOPPED_COUNT stopped Fast API instance(s):${NC}"
        echo
        
        # Display stopped instances
        for i in $(seq 0 $((STOPPED_COUNT-1))); do
            INSTANCE_ID=$(echo "$STOPPED_FLATTENED" | jq -r ".[$i][0]")
            IMAGE_ID=$(echo "$STOPPED_FLATTENED" | jq -r ".[$i][1]")
            INSTANCE_TYPE=$(echo "$STOPPED_FLATTENED" | jq -r ".[$i][2]")
            LAUNCH_TIME=$(echo "$STOPPED_FLATTENED" | jq -r ".[$i][3]")
            
            echo -e "  ${CYAN}Instance $((i+1)):${NC}"
            echo -e "    ID: $INSTANCE_ID"
            echo -e "    Type: $INSTANCE_TYPE"
            echo -e "    Image: $IMAGE_ID"
            echo -e "    Last Launch: $LAUNCH_TIME"
            echo
        done
        
        echo -e "${GREEN}🎉 Scenario 2: RESTART STOPPED - Ready to restart!${NC}"
        echo -e "${WHITE}These instances have cached Docker images and will start quickly (~2-3 minutes).${NC}"
        echo
        
        # Ask user if they want to restart the stopped instances
        echo -e "${YELLOW}[RESTART OPTION]${NC} Would you like to restart the stopped instance(s)?"
        echo "This will start the existing instances with their cached Docker images."
        echo
        
        read -p "Restart stopped instances? (y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}[RESTARTING]${NC} Starting stopped Fast API instances..."
            echo
            
            # Start all stopped instances
            INSTANCE_IDS=$(echo "$STOPPED_FLATTENED" | jq -r '.[] | .[0]' | tr '\n' ' ')
            
            echo -e "${YELLOW}[INFO]${NC} Starting instances: $INSTANCE_IDS"
            aws ec2 start-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION"
            
            echo -e "${YELLOW}[INFO]${NC} Waiting for instances to be running..."
            aws ec2 wait instance-running --instance-ids $INSTANCE_IDS --region "$AWS_REGION"
            
            # Get updated instance information
            RESTARTED_INSTANCES=$(aws ec2 describe-instances \
                --instance-ids $INSTANCE_IDS \
                --region "$AWS_REGION" \
                --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,PrivateIpAddress]' \
                --output json)
            
            echo
            echo -e "${BLUE}======================================${NC}"
            echo -e "${GREEN}✅ Fast API Instances Restarted${NC}"
            echo -e "${BLUE}======================================${NC}"
            echo
            
            # Display restarted instances with API endpoints
            RESTARTED_FLATTENED=$(echo "$RESTARTED_INSTANCES" | jq -r 'flatten(1)')
            RESTARTED_COUNT=$(echo "$RESTARTED_FLATTENED" | jq '. | length')
            
            for i in $(seq 0 $((RESTARTED_COUNT-1))); do
                INSTANCE_ID=$(echo "$RESTARTED_FLATTENED" | jq -r ".[$i][0]")
                PUBLIC_IP=$(echo "$RESTARTED_FLATTENED" | jq -r ".[$i][1]")
                PRIVATE_IP=$(echo "$RESTARTED_FLATTENED" | jq -r ".[$i][2]")
                
                echo -e "${GREEN}[INSTANCE $((i+1))]${NC}"
                echo "Instance ID: $INSTANCE_ID"
                echo "Public IP: $PUBLIC_IP"
                echo "Private IP: $PRIVATE_IP"
                echo "API Endpoint: http://$PUBLIC_IP:8000"
                echo "Health Check: http://$PUBLIC_IP:8000/health"
                echo "Documentation: http://$PUBLIC_IP:8000/docs"
                echo
            done
            
            echo -e "${GREEN}[USAGE]${NC}"
            echo "Test transcription:"
            echo "  ./scripts/step-330-fast-api-test-transcription.sh"
            echo
            echo "Direct API calls:"
            FIRST_IP=$(echo "$RESTARTED_FLATTENED" | jq -r ".[0][1]")
            echo "  curl -X POST http://$FIRST_IP:8000/transcribe-s3 \\"
            echo "    -H 'Content-Type: application/json' \\"
            echo "    -d '{\"s3_input_path\": \"s3://bucket/audio.mp3\", \"s3_output_path\": \"s3://bucket/transcript.json\"}'"
            
            exit 0
        else
            echo -e "${YELLOW}[INFO]${NC} Skipping restart. Proceeding to other deployment options..."
            echo
        fi
    fi
    
    echo -e "${GREEN}[STEP 3]${NC} Checking ECR for existing images..."
    
    # Get ECR images for main deployment logic too
    ECR_IMAGES_MAIN=$(aws ecr describe-images \
        --repository-name "${QUEUE_PREFIX}-fast-api-gpu" \
        --region "$AWS_REGION" \
        --query 'imageDetails[*].[imageTags[0],imageDigest,imagePushedAt,imageSizeInBytes]' \
        --output json 2>/dev/null || echo "[]")
    
    ECR_IMAGE_COUNT_MAIN=$(echo "$ECR_IMAGES_MAIN" | jq '. | length' 2>/dev/null || echo "0")
    
    if [ "$ECR_IMAGE_COUNT_MAIN" -gt 0 ]; then
        echo -e "${GREEN}✓ Found $ECR_IMAGE_COUNT_MAIN Fast API (WhisperX) image(s) in ECR:${NC}"
        echo -e "${CYAN}Repository: ${QUEUE_PREFIX}-fast-api-gpu${NC}"
        echo
        
        # Display ECR images with details and descriptions
        for i in $(seq 0 $((ECR_IMAGE_COUNT_MAIN-1))); do
            IMAGE_TAG=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$i][0]")
            IMAGE_DIGEST=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$i][1] | split(\":\")[1][0:12]")
            PUSH_TIME=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$i][2]")
            IMAGE_SIZE=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$i][3]")
            IMAGE_SIZE_MB=$((IMAGE_SIZE / 1024 / 1024))
            
            # Add descriptive information based on tag
            case "${IMAGE_TAG:-latest}" in
                "s3-enhanced"|"latest-s3")
                    IMAGE_DESC="${GREEN}S3-enhanced with 3 endpoints - RECOMMENDED${NC}"
                    RECOMMENDATION="${GREEN}✓ Use this (S3 + URL + Upload)${NC}"
                    ;;
                "fixed")
                    IMAGE_DESC="${YELLOW}NumPy fix (no S3 support)${NC}"
                    RECOMMENDATION="${YELLOW}△ Basic version${NC}"
                    ;;
                "latest")
                    IMAGE_DESC="${RED}Standard build${NC}"
                    RECOMMENDATION="${RED}⚠ NumPy issues + no S3${NC}"
                    ;;
                "gpu")
                    IMAGE_DESC="${BLUE}GPU-optimized build${NC}"
                    RECOMMENDATION="${BLUE}□ GPU version${NC}"
                    ;;
                *)
                    IMAGE_DESC="${CYAN}Custom build${NC}"
                    RECOMMENDATION="${CYAN}□ Check compatibility${NC}"
                    ;;
            esac
            
            echo -e "  ${CYAN}Image $((i+1)):${NC} $IMAGE_DESC"
            echo -e "    Tag: ${IMAGE_TAG:-latest} ($RECOMMENDATION)"
            echo -e "    Digest: sha256:$IMAGE_DIGEST..."
            echo -e "    Size: ${IMAGE_SIZE_MB}MB"
            echo -e "    Pushed: $PUSH_TIME"
            echo
        done
        
        # Show recommendation for which image to use
        RECOMMENDED_TAG=$(echo "$ECR_IMAGES_MAIN" | jq -r '.[] | select(.[0] == "fixed") | .[0]' 2>/dev/null || echo "")
        if [ -n "$RECOMMENDED_TAG" ]; then
            echo -e "${GREEN}💡 RECOMMENDATION: Use the 'fixed' tag image (NumPy compatibility resolved)${NC}"
        else
            LATEST_TAG=$(echo "$ECR_IMAGES_MAIN" | jq -r 'max_by(.[2]) | .[0]' 2>/dev/null || echo "latest")
            echo -e "${YELLOW}💡 RECOMMENDATION: Use most recent image ('$LATEST_TAG' tag)${NC}"
        fi
        echo
        
        echo -e "${GREEN}🎉 Scenario 3: DEPLOY ONLY - Ready to launch!${NC}"
        echo -e "${WHITE}Use existing image(s) to launch new instances.${NC}"
        echo
        
        # Check if tag was specified via command line
        if [ -n "$USE_TAG" ]; then
            # Verify the tag exists
            TAG_EXISTS=$(echo "$ECR_IMAGES_MAIN" | jq -r --arg tag "$USE_TAG" '.[] | select(.[0] == $tag) | .[0]' 2>/dev/null || echo "")
            if [ -n "$TAG_EXISTS" ]; then
                echo -e "${GREEN}[AUTO-DEPLOY]${NC} Using specified tag: $USE_TAG"
                sed -i "s/FAST_API_DOCKER_IMAGE_TAG=.*/FAST_API_DOCKER_IMAGE_TAG=$USE_TAG/" .env
                echo
                ./scripts/step-320-fast-api-launch-gpu-instances.sh
                exit 0
            else
                echo -e "${RED}[ERROR]${NC} Tag '$USE_TAG' not found in ECR"
                echo -e "${YELLOW}[INFO]${NC} Available tags:"
                echo "$ECR_IMAGES_MAIN" | jq -r '.[] | "  - " + .[0]'
                exit 1
            fi
        fi
        
        # Prompt for image selection
        echo -e "${YELLOW}[SELECT IMAGE]${NC} Which image would you like to deploy?"
        echo
        
        # Create selection menu
        PS3="Enter your choice (1-$ECR_IMAGE_COUNT_MAIN): "
        IMAGE_OPTIONS=()
        for i in $(seq 0 $((ECR_IMAGE_COUNT_MAIN-1))); do
            TAG=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$i][0]")
            SIZE=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$i][3]")
            SIZE_MB=$((SIZE / 1024 / 1024))
            IMAGE_OPTIONS+=("Tag: ${TAG:-latest} (${SIZE_MB}MB)")
        done
        
        select IMAGE_CHOICE in "${IMAGE_OPTIONS[@]}" "Cancel"; do
            if [ "$IMAGE_CHOICE" = "Cancel" ]; then
                echo -e "${YELLOW}[INFO]${NC} Deployment cancelled."
                exit 0
            elif [ -n "$IMAGE_CHOICE" ]; then
                SELECTED_INDEX=$((REPLY-1))
                SELECTED_TAG=$(echo "$ECR_IMAGES_MAIN" | jq -r ".[$SELECTED_INDEX][0]")
                echo
                echo -e "${GREEN}[SELECTED]${NC} Will deploy with tag: ${SELECTED_TAG:-latest}"
                echo
                
                # Update .env file with selected tag
                echo -e "${YELLOW}[INFO]${NC} Updating configuration to use selected image..."
                sed -i "s/FAST_API_DOCKER_IMAGE_TAG=.*/FAST_API_DOCKER_IMAGE_TAG=${SELECTED_TAG:-latest}/" .env
                
                # Launch the instance
                echo -e "${GREEN}[DEPLOYING]${NC} Launching GPU instance with selected image..."
                echo
                ./scripts/step-320-fast-api-launch-gpu-instances.sh
                break
            else
                echo -e "${RED}[ERROR]${NC} Invalid selection. Please try again."
            fi
        done
        
    else
        echo -e "${YELLOW}⚠ No images found in ECR${NC}"
        echo
        echo -e "${GREEN}🔨 Scenario 3: BUILD & DEPLOY - Full pipeline needed${NC}"
        echo -e "${WHITE}Need to build new image and deploy.${NC}"
        echo
        echo -e "${YELLOW}[INFO]${NC} Use these scripts to build and deploy:"
        echo "  - Setup ECR: ./scripts/step-301-fast-api-setup-ecr-repository.sh"
        echo "  - Build image: ./scripts/step-310-fast-api-build-gpu-docker-image.sh"
        echo "  - Launch instance: ./scripts/step-320-fast-api-launch-gpu-instances.sh"
    fi
fi