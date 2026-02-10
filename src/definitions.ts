export interface CapacitorMediastorePlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
