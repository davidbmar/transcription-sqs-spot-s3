#!/bin/bash

# test-gpu-minimal.sh - Minimal GPU test script

set -e

# Load configuration
CONFIG_FILE=".env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found."
    exit 1
fi

# Use regular Ubuntu AMI, not Deep Learning AMI for cleaner start
AMI_ID="ami-0efd9a34b86a437e7"  # Standard Ubuntu 22.04 LTS

# Create minimal user data for GPU testing
cat > /tmp/minimal-gpu-test.sh << 'EOF'
#!/bin/bash
set -e

echo "=== MINIMAL GPU TEST SETUP ==="
echo "Timestamp: $(date)"

# Update system
apt-get update
apt-get install -y wget curl python3-pip

# Install NVIDIA drivers (latest version)
echo "Installing NVIDIA drivers..."
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall

# Install CUDA toolkit
echo "Installing CUDA toolkit..."
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.0-1_all.deb
dpkg -i cuda-keyring_1.0-1_all.deb
apt-get update
apt-get -y install cuda

# Add CUDA to PATH
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /etc/environment
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/environment

# Install PyTorch with CUDA support
pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118

# Test GPU after reboot
cat > /opt/test-gpu.py << 'PYEOF'
import torch
import sys

print("=== GPU TEST RESULTS ===")
print(f"PyTorch version: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")
print(f"CUDA version: {torch.version.cuda}")

if torch.cuda.is_available():
    print(f"GPU count: {torch.cuda.device_count()}")
    print(f"GPU name: {torch.cuda.get_device_name(0)}")
    print(f"GPU memory: {torch.cuda.get_device_properties(0).total_memory / 1024**3:.1f} GB")
    
    # Test tensor operations on GPU
    print("\nTesting GPU tensor operations...")
    x = torch.randn(1000, 1000, device='cuda')
    y = torch.randn(1000, 1000, device='cuda')
    z = torch.mm(x, y)
    print(f"Matrix multiplication successful: {z.device}")
    print("✅ GPU test PASSED")
else:
    print("❌ GPU test FAILED - CUDA not available")
    sys.exit(1)
PYEOF

# Create a service to run GPU test after boot
cat > /etc/systemd/system/gpu-test.service << 'SVCEOF'
[Unit]
Description=GPU Test Service
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/test-gpu.py
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl enable gpu-test.service

echo "=== REBOOTING FOR DRIVER INITIALIZATION ==="
reboot
EOF

# Launch spot instance
echo "Launching minimal GPU test instance..."

USER_DATA=$(base64 -w 0 < /tmp/minimal-gpu-test.sh)

SPOT_REQUEST=$(aws ec2 request-spot-instances \
    --region "$AWS_REGION" \
    --spot-price "0.50" \
    --instance-count 1 \
    --launch-specification "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"g4dn.xlarge\",
        \"KeyName\": \"$KEY_NAME\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP_ID\"],
        \"UserData\": \"$USER_DATA\",
        \"IamInstanceProfile\": {
            \"Name\": \"transcription-worker-profile\"
        }
    }" \
    --query 'SpotInstanceRequests[0].SpotInstanceRequestId' \
    --output text)

echo "Spot request: $SPOT_REQUEST"

# Wait for fulfillment
aws ec2 wait spot-instance-request-fulfilled \
    --region "$AWS_REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST"

# Get instance ID
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
    --region "$AWS_REGION" \
    --spot-instance-request-ids "$SPOT_REQUEST" \
    --query 'SpotInstanceRequests[0].InstanceId' \
    --output text)

echo "Instance launched: $INSTANCE_ID"

# Get IP address
sleep 30
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Public IP: $PUBLIC_IP"
echo ""
echo "To test GPU after reboot (wait 5-10 minutes):"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo journalctl -u gpu-test.service'"
echo ""
echo "To check GPU status:"
echo "  ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'nvidia-smi'"

# Cleanup
rm -f /tmp/minimal-gpu-test.sh