export function syntheticResult(value) {
  return Array.from({ length: 200 }, (_, index) => (value + index) * (index + 3))
    .reduce((sum, item) => sum + item, 0);
}
