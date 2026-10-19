"""Convert the pinned OpenCV SFace ONNX model to the bundled Core ML model.

Use Python 3.12 with coremltools==8.3.0 and onnx==1.17.0.
Usage: python scripts/convert_sface.py /path/to/face_recognition_sface_2021dec.onnx
"""

import hashlib
from pathlib import Path
import sys

import coremltools as ct
import numpy as np
import onnx
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.neural_network.quantization_utils import quantize_weights
from onnx import helper, numpy_helper


def convert(source: Path, destination: Path):
    expected = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
    if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
        raise ValueError("Unexpected SFace model checksum")
    graph = onnx.load(source).graph
    weights = {tensor.name: numpy_helper.to_array(tensor) for tensor in graph.initializer}
    builder = NeuralNetworkBuilder(
        [("image", datatypes.Array(3, 112, 112))], [("embedding", datatypes.Array(128))]
    )
    # Fold ONNX's (RGB - 127.5) / 128 into Core ML's image preprocessing.
    builder.set_pre_processing_parameters(
        image_input_names=["image"], image_scale=1 / 128,
        red_bias=-127.5 / 128, green_bias=-127.5 / 128, blue_bias=-127.5 / 128,
    )
    aliases = {"data": "image"}
    for node in graph.node:
        attributes = {a.name: helper.get_attribute_value(a) for a in node.attribute}
        inputs = [aliases.get(name, name) for name in node.input]
        output = "embedding" if node.output[0] == "fc1" else node.output[0]
        common = dict(name=node.name, input_name=inputs[0], output_name=output)
        if node.op_type in ("Sub", "Mul", "Dropout"):
            aliases[node.output[0]] = inputs[0]
        elif node.op_type == "Conv":
            kernel = weights[node.input[1]]
            pads = attributes["pads"]
            builder.add_convolution(
                **common, kernel_channels=kernel.shape[1], output_channels=kernel.shape[0],
                height=kernel.shape[2], width=kernel.shape[3],
                stride_height=attributes["strides"][0], stride_width=attributes["strides"][1],
                border_mode="valid", groups=attributes["group"],
                W=np.transpose(kernel, (2, 3, 1, 0)), b=None, has_bias=False,
                padding_top=pads[0], padding_left=pads[1], padding_bottom=pads[2], padding_right=pads[3],
            )
        elif node.op_type == "BatchNormalization":
            gamma, beta, mean, variance = [weights[name] for name in node.input[1:]]
            builder.add_batchnorm(**common, channels=len(gamma), gamma=gamma, beta=beta,
                                  mean=mean, variance=variance, epsilon=attributes["epsilon"])
        elif node.op_type == "PRelu":
            builder.add_activation(**common, non_linearity="PRELU", params=weights[node.input[1]].flatten())
        elif node.op_type == "Flatten":
            assert attributes.get("axis", 1) == 1
            builder.add_flatten(**common, mode=0)
        elif node.op_type == "Gemm":
            assert attributes == {"alpha": 1.0, "beta": 1.0, "transA": 0, "transB": 1}
            kernel = weights[node.input[1]]
            builder.add_inner_product(**common, W=kernel, b=weights[node.input[2]],
                                      input_channels=kernel.shape[1], output_channels=kernel.shape[0], has_bias=True)
        else:
            raise ValueError(f"Unsupported ONNX operation: {node.op_type}")
    model = ct.models.MLModel(builder.spec)
    model = quantize_weights(model, nbits=16)
    model.author = "OpenCV Zoo / Yaoyao Zhong; Core ML conversion by Oriel"
    model.license = "Apache-2.0; see SFace-LICENSE.txt"
    model.short_description = "SFace face identity embedding. Aligned 112x112 RGB input; 128-dimensional output."
    model.user_defined_metadata["source_sha256"] = expected
    model.save(str(destination))


if __name__ == "__main__":
    convert(Path(sys.argv[1]), Path(__file__).resolve().parents[1] / "Oriel/Oriel/Resources/SFace.mlmodel")
