import { WebPlugin } from '@capacitor/core';

import type { CapacitorMediastorePlugin } from './definitions';

export class CapacitorMediastoreWeb extends WebPlugin implements CapacitorMediastorePlugin {
  async echo(options: { value: string }): Promise<{ value: string }> {
    console.log('ECHO', options);
    return options;
  }
}
