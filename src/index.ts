import { registerPlugin } from '@capacitor/core';

import type { CapacitorMediastorePlugin } from './definitions';

const CapacitorMediastore = registerPlugin<CapacitorMediastorePlugin>('CapacitorMediastore', {
  web: () => import('./web').then((m) => new m.CapacitorMediastoreWeb()),
});

export * from './definitions';
export { CapacitorMediastore };
