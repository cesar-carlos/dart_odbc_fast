use criterion::{black_box, criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion};
use std::collections::{hash_map::Entry, HashMap};

// Experimental candidate retained only for reproducing the measurements.
// Mixed results did not justify replacing the production baseline.
fn candidate(counts: &mut HashMap<u32, usize>, id: u32) {
    if let Entry::Occupied(mut entry) = counts.entry(id) {
        if *entry.get() <= 1 {
            entry.remove();
        } else {
            *entry.get_mut() -= 1;
        }
    }
}

fn baseline(counts: &mut HashMap<u32, usize>, id: u32) {
    if let Some(count) = counts.get_mut(&id) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            counts.remove(&id);
        }
    }
}

fn benchmark(c: &mut Criterion) {
    let mut group = c.benchmark_group("pool_busy_count");
    for size in [1, 64, 4096] {
        for count in [1, 8] {
            let template: HashMap<u32, usize> = (0..size).map(|id| (id, count)).collect();
            let mut expected = template.clone();
            let mut actual = template.clone();
            for id in 0..=size {
                baseline(&mut expected, id);
                candidate(&mut actual, id);
            }
            assert_eq!(actual, expected);
            let name = format!("{size}_entries_count_{count}");
            for (label, action) in [
                ("baseline", baseline as fn(&mut HashMap<u32, usize>, u32)),
                ("candidate", candidate),
            ] {
                group.bench_with_input(BenchmarkId::new(label, &name), &template, |b, input| {
                    b.iter_batched_ref(
                        || input.clone(),
                        |counts| {
                            for id in 0..=size {
                                action(black_box(counts), black_box(id));
                            }
                            black_box(counts.len());
                        },
                        BatchSize::SmallInput,
                    );
                });
            }
        }
    }
    group.finish();
}

criterion_group!(benches, benchmark);
criterion_main!(benches);
