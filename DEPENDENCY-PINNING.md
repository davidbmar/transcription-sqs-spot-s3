# Dependency Version Pinning Strategy

## 🚨 Critical: Always Pin Dependency Versions

All Python package installations MUST specify exact versions to ensure reproducibility and prevent breaking changes over time.

## Why Version Pinning is Critical

1. **cuDNN Compatibility**: WhisperX → faster-whisper → CTranslate2 → cuDNN version chain is extremely fragile
2. **PyTorch Updates**: New PyTorch versions can bundle different cuDNN versions, breaking compatibility
3. **Breaking Changes**: Libraries like WhisperX can introduce breaking changes (e.g., 3.4.2 requires PyTorch ≥2.5.1)
4. **Reproducibility**: Unpinned dependencies make debugging impossible when issues arise months later

## Pinned Version Stack (DLAMI GPU)

The following versions are tested and known to work together on AWS DLAMI with GPU:

```bash
# Core stack (install with --no-deps)
torch==2.1.2+cu121
torchvision==0.16.2+cu121
torchaudio==2.1.2+cu121
ctranslate2==4.4.0
whisperx==3.1.6

# Supporting libraries
numpy==1.24.4
scipy==1.11.4
librosa==0.10.1
soundfile==0.12.1
openai-whisper==20231117
faster-whisper==1.0.0
transformers==4.38.0
huggingface-hub==0.20.0
pandas==2.0.3
av==11.0.0
pyannote.audio==3.1.1
omegaconf==2.3.0
```

## Installation Order Matters

```bash
# 1. Uninstall existing PyTorch to avoid conflicts
pip3 uninstall -y torch torchvision torchaudio

# 2. Install PyTorch with --no-deps to prevent version override
pip3 install --no-deps --index-url https://download.pytorch.org/whl/cu121 torch==2.1.2

# 3. Install CTranslate2 with --no-deps
pip3 install --no-deps ctranslate2==4.4.0

# 4. Install WhisperX with --no-deps
pip3 install --no-deps whisperx==3.1.6

# 5. Install remaining dependencies
pip3 install numpy==1.24.4 scipy==1.11.4 ...
```

## Scripts Requiring Updates

Run `./scripts/pin-dependency-versions.sh` to find scripts with unpinned dependencies:
- `launch-spot-worker.sh` - needs version pins
- `launch-on-demand-worker.sh` - needs version pins  
- `launch-production-gpu-worker.sh` - needs version pins
- `launch-benchmark-worker.sh` - needs version pins

## Testing New Versions

Before updating any pinned version:
1. Test in isolated environment
2. Verify GPU functionality with `nvidia-smi`
3. Test model loading and warmup
4. Run complete transcription workflow
5. Document any required changes

## Version Conflict Resolution

If you encounter version conflicts:
1. Check the WhisperX GitHub issues for known problems
2. Review the CTranslate2 compatibility matrix
3. Consider using Docker for complete isolation
4. Document the solution in this file