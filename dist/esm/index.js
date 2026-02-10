import { registerPlugin } from '@capacitor/core';
const CapacitorMediastore = registerPlugin('CapacitorMediastore', {
    web: () => import('./web').then((m) => new m.CapacitorMediastoreWeb()),
});
export * from './definitions';
export { CapacitorMediastore };
//# sourceMappingURL=index.js.map