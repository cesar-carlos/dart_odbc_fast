# Bulk Operations Benchmark Results

## Overview

Comparative benchmark between **ArrayBinding** (single-threaded) and **ParallelBulkInsert** (multi-threaded) strategies for bulk insert operations.

## Test Environment

- **Date**: 2026-03-02
- **Database**: SQL Server (localhost)
- **Driver**: SQL Server Native Client 11.0
- **Hardware**: Local development machine
- **Rust Profile**: test (unoptimized + debuginfo)

## Benchmark Configuration

### Small Dataset
- **Rows**: 5,000
- **Array Batch Size**: 1,000
- **Parallel Workers**: 4
- **Parallel Batch Size**: 1,250

### Medium Dataset
- **Rows**: 20,000
- **Array Batch Size**: 1,000
- **Parallel Workers**: 4
- **Parallel Batch Size**: 5,000

## Results

| Scenario | Rows | Array Binding (rows/s) | Parallel Insert (rows/s) | Speedup |
|----------|-----:|----------------------:|-----------------------:|--------:|
| **Small** | 5,000 | 6,723.37 | 17,948.98 | **2.67x** |
| **Medium** | 20,000 | 7,187.88 | 29,124.76 | **4.05x** |

## Analysis

### ArrayBinding (Single-threaded)
- **Throughput**: ~6,700-7,200 rows/sec
- **Characteristics**:
  - Consistent performance across dataset sizes
  - Lower CPU usage (single-threaded)
  - Simpler error handling
  - Suitable for small to medium datasets

### ParallelBulkInsert (Multi-threaded)
- **Throughput**: ~17,900-29,100 rows/sec
- **Characteristics**:
  - Scales better with larger datasets (4.05x speedup for 20K rows)
  - Higher CPU utilization (4 workers)
  - More complex error aggregation
  - Ideal for large batch operations

### Speedup Scaling
- **Small dataset (5K)**: 2.67x faster with parallel approach
- **Medium dataset (20K)**: 4.05x faster with parallel approach
- **Trend**: Speedup increases with dataset size, approaching theoretical 4x limit (4 workers)

## Recommendations

### When to Use ArrayBinding
- Datasets < 10,000 rows
- Low concurrency environments
- Simple error handling requirements
- Memory-constrained systems

### When to Use ParallelBulkInsert
- Datasets > 10,000 rows
- High-throughput requirements
- Multi-core systems available
- Batch import/ETL operations

### BCP (Bulk Copy Program)
- **Status**: Implemented with `sqlserver-bcp` feature flag
- **Fallback**: Transparent fallback to ArrayBinding when BCP unavailable
- **Use Case**: SQL Server-specific bulk operations requiring maximum throughput
- **Note**: Not benchmarked in this test (requires feature flag compilation)

## Future Work

1. **BCP Benchmark**: Compare BCP vs ArrayBinding vs Parallel for SQL Server
2. **Larger Datasets**: Test with 100K+ rows to observe scaling limits
3. **Different Drivers**: Benchmark PostgreSQL, MySQL, Oracle
4. **Release Profile**: Re-run with optimized builds for production estimates
5. **Network Latency**: Test with remote database servers
6. **Column Count Impact**: Measure performance with varying column counts

## Reproducing Results

```bash
cd native
cargo test --test e2e_bulk_compare_benchmark_test -- --ignored --nocapture
```

### Environment Variables (optional)
```bash
export BULK_BENCH_SMALL_ROWS=5000   # default
export BULK_BENCH_MEDIUM_ROWS=20000 # default
```

## Conclusion

ParallelBulkInsert provides **2.67x to 4.05x speedup** over single-threaded ArrayBinding for bulk insert operations, with better scaling for larger datasets. The parallel approach is recommended for batch operations exceeding 10,000 rows on multi-core systems.

For SQL Server-specific workloads requiring maximum throughput, the BCP implementation (with `sqlserver-bcp` feature) provides an additional optimization path with transparent fallback to ArrayBinding.
