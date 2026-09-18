export const DEFAULT_STORAGE_SIGNING_CONCURRENCY = 6;
export const MAINTENANCE_ISSUE_PHOTO_SIGNING_CONCURRENCY = DEFAULT_STORAGE_SIGNING_CONCURRENCY;

export async function mapWithBoundedConcurrency<Item, Result>(
  items: readonly Item[],
  limit: number,
  mapper: (item: Item, index: number) => Promise<Result>,
): Promise<Result[]> {
  if (items.length === 0) return [];
  const results = new Array<Result>(items.length);
  const workerCount = Math.min(Math.max(1, limit), items.length);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < items.length) {
      const currentIndex = nextIndex++;
      results[currentIndex] = await mapper(items[currentIndex], currentIndex);
    }
  }

  const workers = Array.from({ length: workerCount }, () => worker());
  await Promise.all(workers);
  return results;
}
