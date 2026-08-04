"""
Microbenchmark NUM_DOT_PRODUCTS independent secret dot products of length
DOT_PRODUCT_LENGTH (defaults: 16384 by 64). This source is protocol-independent.
Collect runtime and global communication from the MP-SPDZ execution output.
"""

from Compiler.types import regint, sint
from Compiler.library import print_ln


NUM_DOT_PRODUCTS = 16384
DOT_PRODUCT_LENGTH = 64


print_ln('dot product: NUM_DOT_PRODUCTS=%s, DOT_PRODUCT_LENGTH=%s',
         NUM_DOT_PRODUCTS, DOT_PRODUCT_LENGTH)

# Every logical row is an independent dot product. Two secret seeds are
# expanded with small public offsets; sint.matrix_mul() lowers the 16384-by-64
# matrix-vector workload to one optimized secret matmuls instruction.
seeds = sint.input_tensor_via(0, [2, 3], binary=False)
seed_x = seeds[0]
seed_y = seeds[1]

x = seed_x.expand_to_vector(NUM_DOT_PRODUCTS * DOT_PRODUCT_LENGTH) + \
    regint.inc(NUM_DOT_PRODUCTS * DOT_PRODUCT_LENGTH, wrap=8)
y = seed_y.expand_to_vector(DOT_PRODUCT_LENGTH) + \
    regint.inc(DOT_PRODUCT_LENGTH, base=1, wrap=8)
dot_products = sint.matrix_mul(x, y, DOT_PRODUCT_LENGTH)
checksum = dot_products.sum()
print_ln('checksum: %s', checksum.reveal())
