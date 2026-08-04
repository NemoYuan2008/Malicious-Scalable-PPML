"""
Microbenchmark BATCH_SIZE independent fixed-point ReLU evaluations
(default: 1024). This source is protocol-independent. Collect runtime and
global communication from the MP-SPDZ execution output.
"""

from Compiler import ml
from Compiler.library import print_ln
from Compiler.types import cfix, regint, sfix


BATCH_SIZE = 1024
FRACTIONAL_BITS = 16
TOTAL_BITS = 61


sfix.set_precision(FRACTIONAL_BITS, TOTAL_BITS)
print_ln('relu: BATCH_SIZE=%s, f=%s, k=%s',
         BATCH_SIZE, FRACTIONAL_BITS, TOTAL_BITS)

# Derive inputs on both sides of zero from one secret seed and small public
# offsets. ml.relu() is the same vectorized comparison-and-selection path used
# by the ReLU layers in the neural-network programs.
seed = sfix.input_tensor_via(0, [-0.125], binary=False)[0]
offsets = cfix(regint.inc(BATCH_SIZE, wrap=8) - 4,
               f=FRACTIONAL_BITS, k=TOTAL_BITS)
inputs = seed.expand_to_vector(BATCH_SIZE) + offsets
outputs = ml.relu(inputs)
checksum = outputs.sum()
print_ln('checksum: %s', checksum.reveal())
