import { defaultDeps, type Deps } from '../shared/deps.js';
import { objectKey } from '../shared/objects.js';

// The sweep index only contains records whose object may still exist. Each
// run deletes objects past their sweepAt (an unfinished upload, an expired
// link, or a claimed download nobody reported done) and settles the record.
export function createSweeper(deps: Deps) {
  return async function sweep(): Promise<{ swept: number; failed: number }> {
    const now = Math.floor(deps.nowMs() / 1000);
    const due = await deps.store.listDueForSweep(now);

    let swept = 0;
    let failed = 0;
    for (const link of due) {
      try {
        await deps.objects.delete(objectKey(link.exportLinkId));
        await deps.store.settleSwept(link.exportLinkId, link.status, now);
        swept++;
      } catch (err) {
        failed++;
        console.error(
          'sweep failed',
          err instanceof Error ? err.name : 'unknown',
        );
      }
    }
    console.log(JSON.stringify({ swept, failed }));
    if (failed > 0) throw new Error(`${failed} export links failed to sweep`);
    return { swept, failed };
  };
}

let sweeper: ReturnType<typeof createSweeper> | undefined;
export const handler = () => (sweeper ??= createSweeper(defaultDeps()))();
