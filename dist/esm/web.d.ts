import { WebPlugin } from '@capacitor/core';
import type { CapacitorMediastorePlugin, PermissionResult, GetAlbumsResult, GetMediaOptions, GetMediaResult, GetThumbnailOptions, GetThumbnailResult } from './definitions';
export declare class CapacitorMediastoreWeb extends WebPlugin implements CapacitorMediastorePlugin {
    checkPermissions(): Promise<PermissionResult>;
    requestPermissions(): Promise<PermissionResult>;
    getAlbums(): Promise<GetAlbumsResult>;
    getMedia(options: GetMediaOptions): Promise<GetMediaResult>;
    getThumbnail(options: GetThumbnailOptions): Promise<GetThumbnailResult>;
}
