# Native speaker separation attribution

GPInTheBox uses FluidInference/FluidAudio version 0.17.7 (Apache-2.0):
https://github.com/FluidInference/FluidAudio/tree/v0.17.7
The complete library license is in FluidAudio-LICENSE.txt.

Speaker model: FluidInference/diar-streaming-sortformer-coreml,
v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc (balanced v2.1 configuration).
Core ML conversion and distribution: Fluid Inference and GradientDescent2718.
https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml
The conversion model card identifies CC-BY-4.0. GPInTheBox does not alter the downloaded model weights.

Original model: NVIDIA diar_streaming_sortformer_4spk-v2.1.
https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
The original model is distributed under the NVIDIA Open Model License:
https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/

These are third-party models running on Apple Core ML, not Apple Foundation Models.
Downloaded model files and their attribution must be retained together when redistributing.
