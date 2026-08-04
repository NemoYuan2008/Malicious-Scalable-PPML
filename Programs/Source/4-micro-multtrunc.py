"""
Microbenchmark BATCH_SIZE independent fixed-point multiply-then-truncate
operations (default: 4096). This source is protocol-independent. Collect
runtime and global communication from the MP-SPDZ execution output.
"""

from Compiler.types import cfix, regint, sfix
from Compiler.library import print_ln


BATCH_SIZE = 4096
FRACTIONAL_BITS = 16
TOTAL_BITS = 61


sfix.set_precision(FRACTIONAL_BITS, TOTAL_BITS)
print_ln('multiply-then-truncate: BATCH_SIZE=%s, f=%s, k=%s',
         BATCH_SIZE, FRACTIONAL_BITS, TOTAL_BITS)

# Use the same input style and fixed-point representation as the neural-network
# programs, then form the independent operands with small public offsets.
seeds = sfix.input_tensor_via(0, [0.125, 0.25], binary=False)
seed_x = seeds[0]
seed_y = seeds[1]

x_offsets = cfix(regint.inc(BATCH_SIZE, wrap=8),
                 f=FRACTIONAL_BITS, k=TOTAL_BITS)
y_offsets = cfix(regint.inc(BATCH_SIZE, base=1, wrap=8),
                 f=FRACTIONAL_BITS, k=TOTAL_BITS)
x = seed_x.expand_to_vector(BATCH_SIZE) + x_offsets
y = seed_y.expand_to_vector(BATCH_SIZE) + y_offsets
products = x * y
checksum = products.sum()
print_ln('checksum: %s', checksum.reveal())
