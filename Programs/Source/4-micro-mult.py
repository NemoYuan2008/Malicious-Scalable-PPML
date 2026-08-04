"""
Microbenchmark BATCH_SIZE independent secret field multiplications
(default: 524288). This source is protocol-independent. Collect runtime and
global communication from the MP-SPDZ execution output.
"""

from Compiler.types import regint, sint
from Compiler.library import print_ln


BATCH_SIZE = 524288


print_ln('multiplication: BATCH_SIZE=%s', BATCH_SIZE)

# Derive the batch locally from two secret seeds. The small repeating public
# offsets keep all operands bounded while minimizing input-sharing traffic.
seeds = sint.input_tensor_via(0, [2, 3], binary=False)
seed_x = seeds[0]
seed_y = seeds[1]

x = seed_x.expand_to_vector(BATCH_SIZE) + regint.inc(BATCH_SIZE, wrap=8)
y = seed_y.expand_to_vector(BATCH_SIZE) + regint.inc(BATCH_SIZE, base=1,
                                                     wrap=8)
products = x * y
checksum = products.sum()
print_ln('checksum: %s', checksum.reveal())
