// Regenerates test_bitwise.expected: `node gen_bitwise_test.js > test_bitwise.expected`.
// "32" lines use JavaScript's own operators (what Elm's Bitwise compiles to); "64" lines use BigInt with asIntN(64).
// The value lists must equal the ones in test_bitwise.c.
const A32 = [0, 1, -1, 5, -5, 255, 2147483647, 2147483648, -2147483648, -2147483649, 4294967295,
  4294967296, 4294967297, 8589934591, 1099511627779, -1099511627779, 123456789, -123456789];
const A64 = [0n, 1n, -1n, 5n, -5n, 255n, 2147483647n, 2147483648n, -2147483648n, 4294967295n, 4294967296n,
  81985529216486895n, -81985529216486895n, 9223372036854775807n, -9223372036854775808n, 6148914691236517205n];
const N = [0, 1, 2, 31, 32, 33, 63, 64, 65, -1, -32];
const out = [];
for (const a of A32) {
  out.push(`32 not ${a} = ${~a}`);
  for (const b of A32) {
    out.push(`32 and ${a} ${b} = ${a & b}`);
    out.push(`32 or ${a} ${b} = ${a | b}`);
    out.push(`32 xor ${a} ${b} = ${a ^ b}`);
  }
  for (const n of N) {
    out.push(`32 shl ${n} ${a} = ${a << n}`);
    out.push(`32 shr ${n} ${a} = ${a >> n}`);
    out.push(`32 shrz ${n} ${a} = ${a >>> n}`);
  }
}
const s = (x) => BigInt.asIntN(64, x);
for (const a of A64) {
  out.push(`64 not ${a} = ${s(~a)}`);
  for (const b of A64) {
    out.push(`64 and ${a} ${b} = ${s(a & b)}`);
    out.push(`64 or ${a} ${b} = ${s(a | b)}`);
    out.push(`64 xor ${a} ${b} = ${s(a ^ b)}`);
  }
  for (const n of N) {
    const k = BigInt(n) & 63n;
    out.push(`64 shl ${n} ${a} = ${s(a << k)}`);
    out.push(`64 shr ${n} ${a} = ${s(a >> k)}`);
    out.push(`64 shrz ${n} ${a} = ${s(BigInt.asUintN(64, a) >> k)}`);
  }
}
console.log(out.join("\n"));
